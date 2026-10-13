// ตั้งค่า — ชื่อ repo เปิดเผยได้ แต่ห้ามฝัง PAT ไว้ในไฟล์นี้เด็ดขาด
// วิธีที่แนะนำ: commit ไฟล์เข้า curriculums/ แล้ว push (ระบบตรวจอัตโนมัติ ไม่ต้องใช้ token)
const GITHUB_OWNER = "reaperblitz";
const GITHUB_REPO = "Curriculum-Reviewer";
const WORKFLOW_ID = "review.yml";

// หมายเหตุ: workflow จะอ่านไฟล์จาก curriculums/ ใน git เสมอ
// ต้อง commit/push ไฟล์ curriculums/<ชื่อไฟล์> ก่อน — การกดปุ่มอย่างเดียวอัปโหลดไฟล์ไม่ได้
// ถ้า push ไฟล์ PDF เข้า curriculums/ ระบบจะเริ่มตรวจให้เองโดยไม่ต้องใช้ token

async function startAudit() {
    const fileInput = document.getElementById("curriculumFile");
    const statusCard = document.getElementById("statusCard");
    const statusText = document.getElementById("statusText");

    if (!fileInput.files.length) {
        alert("กรุณาเลือกไฟล์หลักสูตรก่อน");
        return;
    }

    const fileName = fileInput.files[0].name;
    const pat = prompt(
        "วาง GitHub PAT แบบ fine-grained (สิทธิ์ Actions: write) เพื่อสั่งตรวจ\n" +
        "เว้นว่างเพื่อยกเลิก วิธีที่แนะนำ: commit ไฟล์ curriculums/" + fileName + " ขึ้น git แทน (ตรวจอัตโนมัติ ไม่ต้องใช้ token)"
    );
    if (!pat) {
        statusCard.classList.remove("hidden");
        statusText.innerText =
            "ยกเลิกแล้ว ถ้าไม่ใช้ token ให้ commit ไฟล์เข้าโฟลเดอร์ curriculums/ แล้ว push — ระบบจะเริ่มตรวจให้เอง";
        return;
    }

    statusCard.classList.remove("hidden");
    statusText.innerText = `กำลังสั่งตรวจ: ${fileName} (ต้อง commit curriculums/${fileName} ไว้ก่อนแล้ว)...`;

    try {
        const response = await fetch(
            `https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/actions/workflows/${WORKFLOW_ID}/dispatches`,
            {
                method: "POST",
                headers: {
                    "Accept": "application/vnd.github+json",
                    "Authorization": `Bearer ${pat}`,
                    "X-GitHub-Api-Version": "2022-11-28",
                    "Content-Type": "application/json"
                },
                body: JSON.stringify({
                    ref: "main",
                    inputs: {
                        curriculum_file: fileName
                    }
                })
            }
        );

        if (response.status === 204) {
            statusText.innerText = " สั่งตรวจสำเร็จ ติดตามความคืบหน้าและผลตรวจได้ทาง Discord";
        } else {
            const errData = await response.json();
            statusText.innerText = ` สั่งตรวจไม่สำเร็จ: ${errData.message}`;
        }
    } catch (err) {
        statusText.innerText = ` เกิดข้อผิดพลาด: ${err.message}`;
    }
}
