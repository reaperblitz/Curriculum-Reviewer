#!/usr/bin/env bash
# ============================================================
# สคริปต์ตรวจหลักสูตร — เริ่มงาน + ส่งพรอมต์ให้ OpenCode ทีละขั้น
# ท่าเดียวกับ wayla-work (bare run ไม่มี flag): opencode run "$PROMPT"
# ไม่บังคับโมเดล ไม่บังคับคีย์ ไม่มีแปลง PDF — AI อ่านไฟล์เองทั้งหมด
# ขั้นไหนล้มก็ข้ามไป งานจบเขียวเสมอ (แบบ wayla-work) แล้วรายงานจะบอกตรง ๆ
# ============================================================
set -euo pipefail

TARGET_INPUT="${1:-${CURRICULUM_FILE:-}}"
# โมเดลดีฟอลต์: ฟรี (เปลี่ยนด้วย Variables OPENCODE_MODEL)
MODEL="${OPENCODE_MODEL:-opencode/space-bunny-free}"
STRICTNESS="${AUDIT_STRICTNESS:-standard}"   # standard | strict
CALL_TIMEOUT="${OPENCODE_TIMEOUT_SEC:-900}"  # กันงานค้าง: สูงสุด 15 นาทีต่อ 1 พรอมต์
TMPDIR_WORK="${RUNNER_TEMP:-/tmp}/audit-$$"
mkdir -p "$TMPDIR_WORK"

# ---------- 0. หาไฟล์เป้าหมาย (ไม่แตะเนื้อหา PDF) ----------
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

STRICT_LINE="ตรวจตามเกณฑ์ปกติ"
if [[ "$STRICTNESS" == "strict" ]]; then
  STRICT_LINE="ตรวจแบบเข้มงวด (strict): จุดที่น่าสงสัยให้ตีเป็น FAIL ไว้ก่อน"
fi
echo "▶ เป้าหมาย: $TARGET | โมเดล: $MODEL | ความเข้ม: $STRICTNESS"

# ไม่บังคับคีย์ — ถ้ามีคีย์ใน Secrets opencode จะใช้เองผ่าน env
# ถ้าไม่มีเลยก็ลองรัน ขั้นไหนไม่สำเร็จข้ามไป รายงานบอกตรง ๆ (ท่าเดียวกับ wayla-work)
if [[ -z "${ANTHROPIC_API_KEY:-}" && -z "${OPENAI_API_KEY:-}" && -z "${OPENCODE_API_KEY:-}" ]]; then
  echo "ℹ ไม่มีคีย์ใน Secrets — ลองรันเลย ถ้า AI ไม่ตอบ รายงานจะส่งให้คนตรวจ" >&2
fi

SHA="$(sha256sum "$TARGET" | cut -d' ' -f1)"
TODAY="$(date -u +%Y-%m-%d)"
DRAFT_FILE="$TMPDIR_WORK/draft.md"

# ---------- ตัวช่วย: เติมตัวแปรลงพรอมต์ไฟล์ (แบบ wayla-work ต่อท้ายตัวแปร) ----------
render() { # $1=prompt file, rest: NAME=value
  local file="$1"; shift
  local text; text="$(<"$file")"
  local kv k v
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    text="${text//\{\{$k\}\}/$v}"
  done
  printf '%s' "$text"
}

# ---------- ตัวช่วย: เรียก opencode (ล้มได้ ไม่ตาย) ----------
run_oc() { # $1=full prompt → stdout; ว่างเปล่าถ้าล้ม
  local prompt="$1" out
  if out="$(timeout "$CALL_TIMEOUT" opencode run --model "$MODEL" "$prompt" 2>"$TMPDIR_WORK/oc_err.log")"; then
    printf '%s' "$out"
  else
    echo "⚠ opencode ขั้นนี้ไม่สำเร็จ — ข้ามไปขั้นต่อไป" >&2
    cat "$TMPDIR_WORK/oc_err.log" >&2 || true
    printf ''
  fi
}

# ---------- 1. สำรวจโฟลเดอร์ pdf/ ----------
echo "▶ [1/6] สำรวจเอกสารอ้างอิงใน pdf/ ..."
ORIENT="$(run_oc "$(render prompts/orient.md "TARGET=$TARGET" "STRICT_LINE=$STRICT_LINE")")"
[[ -n "$ORIENT" ]] && echo "$ORIENT"

# ---------- 2. อ่านไฟล์เป้าหมาย + ร่างผลตรวจ ----------
echo "▶ [2/6] อ่านหลักสูตรเป้าหมายและร่างผลตรวจ ..."
DRAFT="$(run_oc "$(render prompts/audit.md "TARGET=$TARGET" "STRICT_LINE=$STRICT_LINE" "ORIENT=${ORIENT:-(ไม่มีผลสำรวจ)}")")"
printf '%s' "$DRAFT" > "$DRAFT_FILE"

# ---------- 3-5. โหวต 3 เสียง (รันใหม่อิสระต่อกัน) ----------
vote() { # $1=focus
  run_oc "$(render prompts/vote.md "DRAFT_FILE=$DRAFT_FILE" "TARGET=$TARGET" "FOCUS=$1")"
}
echo "▶ [3/6] ขอเสียงโหวตที่ 1 (เกณฑ์) ..."
V1="$(vote "ความสอดคล้องตามเกณฑ์บังคับทุกข้อ เกณฑ์ข้อไหนตกถือว่าตก")"
[[ -n "$V1" ]] && echo "$V1"
echo "▶ [4/6] ขอเสียงโหวตที่ 2 (คุณภาพวิชาการ) ..."
V2="$(vote "คุณภาพวิชาการ ผลลัพธ์การเรียนรู้ ความสอดคล้องของหลักสูตรและการวัดผล เทียบกับตัวอย่าง Blueprint")"
[[ -n "$V2" ]] && echo "$V2"
echo "▶ [5/6] ขอเสียงโหวตที่ 3 (ความครบถ้วน) ..."
V3="$(vote "ความครบถ้วนของเอกสาร โครงสร้าง หมวดหมู่ ตารางและภาคผนวกที่ต้องมี")"
[[ -n "$V3" ]] && echo "$V3"
VOTES="เสียงที่ 1 (เกณฑ์): ${V1:-(ไม่มีผลโหวต)}
เสียงที่ 2 (คุณภาพ): ${V2:-(ไม่มีผลโหวต)}
เสียงที่ 3 (ครบถ้วน): ${V3:-(ไม่มีผลโหวต)}"

# ---------- 6. รวมรายงานฉบับเต็ม (ต่อเซสชันขั้น 1-2) ----------
echo "▶ [6/6] รวมรายงานฉบับเต็ม ..."
FINAL="$(run_oc "$(render prompts/finalize.md "DRAFT=${DRAFT:-(ไม่มีร่าง)}" "VOTES=$VOTES")")"
if [[ -z "${FINAL//[[:space:]]/}" ]]; then
  FINAL="> ⚠️ รอบนี้ AI ไม่สามารถตรวจได้ (opencode ไม่ตอบ) ไฟล์ได้รับแล้ว กรุณาส่งคณะกรรมการพิจารณาโดยตรง"
fi

# ---------- นับคะแนน (นับคำ ไม่ได้อ่าน PDF) + เขียนรายงาน ----------
DENIES="$(grep -oi 'VOTE:[[:space:]]*DENY' <<<"$V1 $V2 $V3" | wc -l | tr -d ' ' || true)"
APPROVES="$(grep -oi 'VOTE:[[:space:]]*APPROVE' <<<"$V1 $V2 $V3" | wc -l | tr -d ' ' || true)"
if [[ "$DENIES" -ge 2 ]]; then
  if grep -qi 'FAIL' <<<"$FINAL" && grep -qi 'เกณฑ์บังคับ\|binding' <<<"$FINAL"; then VERDICT="FAIL"; else VERDICT="NEEDS REVISION"; fi
else
  VERDICT="PASS"
fi
if [[ "$DENIES" -eq 0 && "$APPROVES" -eq 0 ]]; then VERDICT="NEEDS REVISION"; fi # อ่านโหวตไม่ออก -> ให้คนตรวจ

mkdir -p reports
REPORT="reports/audit_${SAFE_NAME%.*}.md"
{
  echo "# รายงานการตรวจหลักสูตร: $SAFE_NAME"
  echo ""
  echo "**คำตัดสิน (เสียงข้างมาก): $VERDICT** (APPROVE=$APPROVES, DENY=$DENIES, ความเข้ม=$STRICTNESS)"
  echo ""
  echo "- วันที่ตรวจ (UTC): $TODAY"
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

# ---------- แจ้ง Discord + outputs ให้ workflow (มีหรือไม่มี webhook ก็จบเขียว) ----------
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
  echo "ℹ ไม่มี DISCORD_WEBHOOK_URL — ข้ามการแจ้งเตือน"
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
