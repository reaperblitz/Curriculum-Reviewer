#!/usr/bin/env bash
# ============================================================
# สคริปต์ตรวจหลักสูตร — ทำหน้าที่เริ่มงาน + ส่งพรอมต์ให้ OpenCode เท่านั้น
# NO PDF PARSING. OpenCode อ่านไฟล์ PDF เองทั้งหมดด้วย read tool
# ขั้นตอน: orient -> audit -> vote x3 -> finalize -> tally -> แจ้ง Discord
# ============================================================
set -euo pipefail

TARGET_INPUT="${1:-${CURRICULUM_FILE:-}}"
MODEL="${OPENCODE_MODEL:-opencode/space-bunny-free}"
STRICTNESS="${AUDIT_STRICTNESS:-standard}"   # standard | strict
CALL_TIMEOUT="${OPENCODE_TIMEOUT_SEC:-900}"  # กันงานค้าง: สูงสุด 15 นาทีต่อ 1 พรอมต์
TMPDIR_WORK="${RUNNER_TEMP:-/tmp}/audit-$$"
mkdir -p "$TMPDIR_WORK"

# ---------- 0. ตรวจความพร้อม (ไม่แตะเนื้อหา PDF) ----------
command -v opencode >/dev/null 2>&1 || {
  echo "❌ ไม่พบคำสั่ง opencode — ติดตั้งก่อน: npm install --global @opencode/cli" >&2
  exit 1
}
if [[ -z "${ANTHROPIC_API_KEY:-}" && -z "${OPENAI_API_KEY:-}" && -z "${OPENCODE_API_KEY:-}" ]]; then
  echo "⚠ ไม่พบ API key ใน Secrets — จะลองรันด้วยสิทธิ์ดีฟอลต์ของ OpenCode ก่อน" >&2
  echo "  (โมเดลฟรีของ OpenCode ใช้ได้เฉพาะในแอป OpenCode หรือเมื่อมี OPENCODE_API_KEY" >&2
  echo "   ถ้ารันแล้วล้มเหลว ให้เพิ่ม Secrets: OPENCODE_API_KEY (ใช้โมเดลฟรี) หรือ ANTHROPIC_API_KEY)" >&2
fi

# ป้องกัน path traversal: รับเฉพาะชื่อไฟล์ ต้องอยู่ใน curriculums/
SAFE_NAME="$(basename -- "$TARGET_INPUT")"
if [[ -z "$SAFE_NAME" ]]; then
  # ไม่ได้ระบุไฟล์: ใช้ PDF ไฟล์แรกใน curriculums/
  SAFE_NAME="$(ls curriculums/*.pdf 2>/dev/null | head -n1 | xargs -r basename -- || true)"
fi
TARGET="curriculums/$SAFE_NAME"
if [[ ! -f "$TARGET" ]]; then
  echo "❌ ไม่พบไฟล์ $TARGET — commit ไฟล์เข้าโฟลเดอร์ curriculums/ ก่อน แล้วค่อยสั่งตรวจ" >&2
  exit 1
fi
echo "▶ เป้าหมาย: $TARGET | โมเดล: $MODEL | ความเข้ม: $STRICTNESS"

SHA="$(sha256sum "$TARGET" | cut -d' ' -f1)"
TODAY="$(date -u +%Y-%m-%d)"
DRAFT_FILE="$TMPDIR_WORK/draft.md"

STRICT_LINE="ตรวจตามเกณฑ์ปกติ"
if [[ "$STRICTNESS" == "strict" ]]; then
  STRICT_LINE="ตรวจแบบเข้มงวด (strict): จุดที่น่าสงสัยให้ตีเป็น FAIL ไว้ก่อน"
fi

run_oc() { # $1=agent $2=prompt $3=use_continue(yes/no)
  local agent="$1" prompt="$2" cont="$3"
  local args=(run --standalone --model "$MODEL" --agent "$agent")
  [[ "$cont" == "yes" ]] && args+=(--continue)
  timeout "$CALL_TIMEOUT" opencode "${args[@]}" "$prompt"
}

# ---------- 1. พรอมต์ที่ 1: สำรวจโฟลเดอร์ pdf/ ----------
echo "▶ [1/6] สำรวจเอกสารอ้างอิงใน pdf/ ..."
PROMPT_ORIENT="คุณคือ auditor ตรวจหลักสูตรมหาวิทยาลัยไทย (${STRICT_LINE})
เป้าหมายที่จะตรวจคือ: ${TARGET}
ขั้นที่ 1 — สำรวจโฟลเดอร์ pdf/ ด้วยเครื่องมือ glob/read ของคุณเอง:
- เอกสารเกณฑ์บังคับ (ไฟล์ที่ขึ้นต้นด้วย เกณฑ์ที่ใช้ตรวจ)
- ตัวอย่าง Blueprint ใน pdf/เล่มหลักสูตร/ ที่ตรงสายวิชาของเป้าหมายที่สุด 2 ไฟล์ (อ่านโครงสร้าง/สารบัญก่อน)
- มติกลั่นกรอง ใน pdf/มติกลั่นกรองหลักสูตร_Report/ ที่เป็นการตีกลับหรือสั่งแก้ไข 2-3 เรื่องล่าสุด
ห้ามอ่านทุกไฟล์ — เลือกเฉพาะที่เกี่ยวข้อง
ตอบสั้น ๆ เป็นภาษาไทย: ใช้เกณฑ์ฉบับไหน, เลือกตัวอย่างอะไรเพราะอะไร, ประเด็นตีกลับที่พบบ่อยมีอะไรบ้าง"
ORIENT="$(run_oc auditor "$PROMPT_ORIENT" no)"
echo "$ORIENT"

# ---------- 2. พรอมต์ที่ 2: อ่านไฟล์เป้าหมาย + ร่างผลตรวจ ----------
echo "▶ [2/6] อ่านหลักสูตรเป้าหมายและร่างผลตรวจ ..."
PROMPT_AUDIT="ขั้นที่ 2 — อ่านไฟล์ ${TARGET} ทั้งไฟล์ด้วย read tool ของคุณ แล้วตรวจตามเกณฑ์ที่สำรวจมา (${STRICT_LINE})
เขียนร่างผลการตรวจเป็นภาษาไทย (~800-1500 คำ):
1. สถานะเบื้องต้น: PASS / NEEDS REVISION / FAIL
2. ประเด็นที่ไม่สอดคล้อง (มีเลขข้อ อ้างชื่อเกณฑ์/ตัวอย่างทุกข้อ)
3. ข้อเสนอแนะแก้ไข เรียงตามความรุนแรง
ห้ามแต่งเลขหน้าหรือเกณฑ์ที่ไม่มีจริง ส่วนไหนอ่านไม่ได้ให้ระบุไว้ชัดเจน
ตอบด้วยร่างรายงานฉบับเต็ม"
DRAFT="$(run_oc auditor "$PROMPT_AUDIT" yes)"
echo "$DRAFT" > "$DRAFT_FILE"

# ---------- 3-5. พรอมต์ที่ 3,4,5: โหวต 3 เสียง (เซสชันใหม่อิสระต่อกัน) ----------
vote() { # $1=agent $2=มุมมอง
  local agent="$1" focus="$2"
  run_oc "$agent" "คุณคือ ${agent} ตรวจหลักสูตรมหาวิทยาลัยไทย
อ่านไฟล์ 2 ไฟล์นี้ด้วย read tool ของคุณเอง: ${DRAFT_FILE} (ร่างผลตรวจ) และ ${TARGET} (หลักสูตรเป้าหมาย)
ตรวจเฉพาะมุมมองของคุณ: ${focus}
แล้วตอบตามรูปแบบนี้เท่านั้น:
VOTE: APPROVE หรือ DENY
RATIONALE: เหตุผล 1-3 ประโยคภาษาไทย อ้างเกณฑ์หรือส่วนที่พบ" no
}
echo "▶ [3/6] ขอเสียงโหวตที่ 1 (เกณฑ์) ..."
V1="$(vote compliance-voter "ความสอดคล้องตามเกณฑ์บังคับทุกข้อ เกณฑ์ข้อไหนตกถือว่าตก")"
echo "$V1"
echo "▶ [4/6] ขอเสียงโหวตที่ 2 (คุณภาพวิชาการ) ..."
V2="$(vote quality-voter "คุณภาพวิชาการ ผลลัพธ์การเรียนรู้ ความสอดคล้องของหลักสูตรและการวัดผล เทียบกับตัวอย่าง Blueprint")"
echo "$V2"
echo "▶ [5/6] ขอเสียงโหวตที่ 3 (ความครบถ้วน) ..."
V3="$(vote completeness-voter "ความครบถ้วนของเอกสาร โครงสร้าง หมวดหมู่ ตารางและภาคผนวกที่ต้องมี")"
echo "$V3"
VOTES="เสียงที่ 1 (เกณฑ์): ${V1}
เสียงที่ 2 (คุณภาพ): ${V2}
เสียงที่ 3 (ครบถ้วน): ${V3}"

# ---------- 6. พรอมต์ที่ 6: รวมรายงานฉบับเต็ม ----------
echo "▶ [6/6] รวมรายงานฉบับเต็ม ..."
PROMPT_FINAL="ขั้นสุดท้าย — ร่างผลตรวจของคุณ กับผลโหวต 3 เสียง:
${VOTES}
กติกาเสียงข้างมาก: DENY ตั้งแต่ 2 เสียงขึ้นไป = NEEDS REVISION (ถ้าขัดเกณฑ์บังคับ = FAIL) น้อยกว่านั้น = PASS
เขียนรายงานฉบับเต็มเป็นภาษาไทย ประกอบด้วย:
## สรุปสถานะ, ## ตารางรายเกณฑ์ (เกณฑ์ -> PASS/FAIL/NA + หลักฐาน), ## ประเด็นที่พบ, ## ข้อเสนอแนะ, ## Votes (ตาราง 3 เสียงพร้อมเหตุผล), ## Final Verdict
ตอบด้วยรายงานฉบับเต็มเท่านั้น"
FINAL="$(run_oc auditor "$PROMPT_FINAL" yes)"

# ---------- นับคะแนน (นับคำ ไม่ได้อ่าน PDF) + เขียนรายงาน ----------
DENIES="$(grep -oi 'VOTE:[[:space:]]*DENY' <<<"$V1 $V2 $V3" | wc -l | tr -d ' ')"
APPROVES="$(grep -oi 'VOTE:[[:space:]]*APPROVE' <<<"$V1 $V2 $V3" | wc -l | tr -d ' ')"
if [[ "$DENIES" -ge 2 ]]; then
  if grep -qi 'FAIL' <<<"$FINAL" && grep -qi 'เกณฑ์บังคับ\|binding' <<<"$FINAL"; then VERDICT="FAIL"; else VERDICT="NEEDS REVISION"; fi
else
  VERDICT="PASS"
fi
if [[ "$DENIES" -eq 0 && "$APPROVES" -eq 0 ]]; then VERDICT="NEEDS REVISION"; fi # อ่านโหวตไม่ออก -> ให้คนตรวจ

mkdir -p reports
REPORT="reports/audit_${SAFE_NAME%.pdf}.md"
{
  echo "# รายงานการตรวจหลักสูตร: $SAFE_NAME"
  echo ""
  echo "**คำตัดสิน (เสียงข้างมาก): $VERDICT** (APPROVE=$APPROVES, DENY=$DENIES, ความเข้ม=$STRICTNESS)"
  echo ""
  echo "- วันที่ตรวจ (UTC): $TODAY | โมเดล: $MODEL"
  echo "- ไฟล์เป้าหมาย: \`$TARGET\` | SHA-256: \`$SHA\`"
  echo "- หมายเหตุ: รายงานนี้จัดทำโดย AI เพื่อประกอบการพิจารณาเบื้องต้น การตัดสินขั้นสุดท้ายเป็นของคณะกรรมการกลั่นกรองหลักสูตร"
  echo ""
  echo "$FINAL"
} > "$REPORT"
echo "✔ เขียนรายงาน: $REPORT"

# ประวัติการตรวจ (ต่อท้าย INDEX)
INDEX="reports/INDEX.md"
[[ -f "$INDEX" ]] || echo "| วันที่ | ไฟล์ | คำตัดสิน | โหวต | รายงาน |" > "$INDEX"
[[ "$(head -n1 "$INDEX")" == "| วันที่"* ]] || sed -i '1i | วันที่ | ไฟล์ | คำตัดสิน | โหวต | รายงาน |' "$INDEX"
echo "| $TODAY | \`$SAFE_NAME\` | $VERDICT | A=$APPROVES D=$DENIES | \`$REPORT\` |" >> "$INDEX"

# ---------- แจ้ง Discord + outputs ให้ workflow ----------
if [[ -n "${DISCORD_WEBHOOK_URL:-}" ]]; then
  SHORT="$(head -c 1800 "$REPORT")"
  if command -v jq >/dev/null 2>&1; then
    PAYLOAD="$(jq -n --arg t "📊 ตรวจเสร็จ: $SAFE_NAME → $VERDICT" --arg d "$SHORT" \
      '{embeds:[{title:$t, description:$d, color: (if ($t|contains("PASS")) then 3066993 else 15158332 end)}]}')"
  else
    PAYLOAD="{\"content\":\"📊 ตรวจเสร็จ: $SAFE_NAME → $VERDICT (ดูรายงานใน $REPORT)\"}"
  fi
  curl -fsSL -m 15 -H "Content-Type: application/json" -d "$PAYLOAD" "$DISCORD_WEBHOOK_URL" || echo "⚠ ส่ง Discord ไม่สำเร็จ"
else
  echo "⚠ ไม่ได้ตั้งค่า DISCORD_WEBHOOK_URL — ข้ามการแจ้งเตือน"
fi

[[ -n "${GITHUB_OUTPUT:-}" ]] && {
  echo "verdict=$VERDICT" >> "$GITHUB_OUTPUT"
  echo "report_path=$REPORT" >> "$GITHUB_OUTPUT"
  echo "denies=$DENIES" >> "$GITHUB_OUTPUT"
}
[[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && {
  echo "## 📊 ตรวจหลักสูตร: \`$SAFE_NAME\`" >> "$GITHUB_STEP_SUMMARY"
  echo "**คำตัดสิน:** $VERDICT (APPROVE=$APPROVES, DENY=$DENIES)" >> "$GITHUB_STEP_SUMMARY"
  echo "รายงาน: \`$REPORT\`" >> "$GITHUB_STEP_SUMMARY"
}
echo "✔ เสร็จสิ้น คำตัดสิน=$VERDICT"
