# Deep Dive: Khởi Nguồn Tầm Nhìn `bootc` & Điểm Hạn Chế Hiện Tại

> Bài viết này được đúc kết từ chiến lược "0-CVE OS", "Patch is Policy" và những thay đổi nguyên thủy từ đội ngũ bảo mật Kernel Linux, nhằm giúp các Kỹ sư DevOps/SRE hiểu rõ LÝ DO TẠI SAO `bootc` (hay RHEL Image Mode) lại là tương lai của cơ sở hạ tầng.
> Mục tiêu: Dùng làm luận điểm bảo vệ giải pháp (pitching) trước Ban Giám Đốc (C-Level) hoặc System Owners.

---

## 1. Tại sao lại là `bootc`? (Tầm nhìn của một Senior/Head of Tech)

Nếu một ngày Sếp hỏi: *"Tại sao team ảo hóa của mày lại muốn bỏ Packer + Ansible để chuyển sang dùng cái `bootc` phức tạp này?"*. Đây là câu trả lời của bạn:

### A. Sự Phá Sản Của Quy Trình Vá Lỗi Truyền Thống (The End of Traditional Patching)
Nhiều năm qua, ngành IT doanh nghiệp tuân theo một luật bất thành văn: *"Quét lỗ hổng, nếu CVSS > 7.0 thì vá ngay lập tức trong vòng 30 ngày"*. Nhưng quy trình này vừa chính thức sụp đổ.

Theo **Greg Kroah-Hartman** (Trưởng nhóm bảo mật Linux Kernel): Đội ngũ Linux Kernel đã trở thành tổ chức cấp phát CVE (CNA) và họ đang phát hành hàng ngàn CVE cho hầu hết mọi bản vá lỗi. Điểm cốt tử là: **Họ từ chối gán điểm CVSS**.
Tại sao? Bởi vì độ nghiêm trọng (Severity) của một lỗi Kernel phụ thuộc 100% vào việc người dùng đang chạy cái gì (một con server web hay một thiết bị công nghiệp). Việc chấm điểm mù quáng là dối trá.

**Hệ lụy:** NIST/NVD không còn điểm CVSS để bạn dựa dẫm. Quy trình "Triage" (phân loại xem lỗi nào nguy hiểm để vá) bằng tay trở thành một cơn ác mộng không thể mở rộng. 

### B. Patch is Policy & Hội chứng "Update Fatigue"
Khi không thể Triage thủ công, ngành bảo mật chia làm 2 ngã rẽ:
1. **The Chainguard Way (Tốc độ):** Cắt gọt hệ điều hành (distroless) nhỏ nhất có thể và cập nhật liên tục mỗi ngày để đạt trạng thái **0-CVE** (Không có lỗ hổng nào được biết đến).
2. **Update Fatigue (Sự mệt mỏi):** Khi cập nhật hệ điều hành liên tục cho các máy ảo (VM) dạng "thú cưng" (Pet - Stateful), các quản trị viên mang tâm lý sợ hãi (**Reboot Anxiety**). Họ sợ lệnh `dnf update` sẽ làm vỡ driver, sập ứng dụng và cực kỳ khó rollback (quay xe) lại bản backup cũ một cách tự động.

### C. Lời Giải: Đối xử với toàn bộ Máy Ảo như một Container Image
`bootc` được sinh ra để dung hòa tốc độ vá lỗi và sự ổn định của Doanh nghiệp. Nó biến toàn bộ HDH thành một container image `scratch`:
- **Atomic Certainty (Tính giao dịch nguyên tử):** Bạn không SSH vào server để `dnf update` vá lỗi. Nó diễn ra bằng cách boot sang một cây (tree) Image mới. Khởi động thất bại vòng Healthcheck? Tự chạy lùi về bản cũ (Rollback). Sự đáng sợ của cập nhật bị triệt tiêu hoàn toàn. Nỗi sợ "Update Fatigue" không còn.
- **Environmental Triage:** Quét lỗ hổng không còn diễn ra trên 1 cái máy ảo sống. Nó quét trên luồng CI/CD (Quét cái file Dockerfile/Container). Lỗi nào nằm trong Image thì mới là lỗi của mình.
- **Thuyết phục Security/Compliance:** Bạn không mang đến một HDH kỳ lạ nào cả. Bên dưới `bootc` vẫn là RHEL/CentOS. Bạn vẫn có thể xài lại toàn bộ tập luật hardening chuẩn FIPS, NIST có sẵn của công ty, chỉ là cách *Giao Hàng (Delivery)* khác đi.

Hành động vá lỗi hệ điều hành giờ đây chỉ là một Pipeline CI tẻ nhạt, tự động đằng sau cánh gà, kéo MTTR (Mean Time To Recovery) và Downtime về gần như bằng 0 khi vá bảo mật. Đưa định nghĩa **Zero-CVE VMs** ra đời thực.

---

## 2. Điểm Hạn Chế ("Sự Đánh Đổi") Hiện Tại của `bootc`

Là một DevOps giỏi, bạn phải vạch ra rõ ràng ranh giới và những mặt trái của kiến trúc Immutable OS này trước lãnh đạo, phòng trường hợp "đụng tường":

### A. Sự xung đột với "Legacy Apps" (Ứng dụng cũ)
- **Filesystem Read-Only:** Đây là rào cản chí mạng. `bootc` khóa cứng (Read-Only) thư mục `/usr` và gần như toàn bộ hệ điều hành. Chỉ chừa lại `/etc` (cho config) và `/var` (cho dữ liệu) là ghi được (Read-Write).
- Nếu các ứng dụng cũ (như một số phần mềm ngân hàng/core-banking) có thói quen "bạ đâu ghi đấy", ví dụ như đổ log thẳng vào thư mục cài đặt gốc `/opt/myapp/logs`, ứng dụng đó sẽ lập tức **crash** khi chạy trên bootc. Vượt qua điều này đòi hỏi phải quy chuẩn hóa ứng dụng hoặc tận dụng `systemd-tmpfiles`.

### B. Quản Lý Trạng Thái Cấu Hình (State Drift & Configuration Management)
- **Không có "Fix Nóng" (Hot-fixes):** Giả sử 2h sáng server bị lỗi mạng, Sysadmin SSH vào máy ảo, chạy lệnh sửa file gốc hệ thống để cứu app. Sáng hôm sau khi máy reboot hoặc tiến hành update image bootc mới, bản sửa lỗi "chạy bằng tay" đó sẽ **bốc hơi**, hệ thống phục hồi lại nguyên trạng Container Image trên GitHub.
- **Phải thay đổi Mindset:** Mọi thay đổi về cấu hình HĐH phải được commit dạng mã (Infrastructure as Code) vào `Containerfile`, build lại CI và chờ máy chủ pull về. Tính cục bộ bị loại bỏ hoàn toàn.

### C. Sự Đứt Gãy Ở Quản Lý Drivers / Kernel Modules (Đặc biệt GPU)
- Đối với Máy ảo chạy thiết bị ngoại vi phức tạp (Ví dụ kẹp NVIDIA GPUs để chạy AI), việc nạp kernel modules của bên thứ 3 vào bootc là một cơn ác mộng (Out-of-Tree modules).
- Bạn phải biên dịch driver (kmod pull, akmods) trực tiếp vào bên trong Container Image trên luồng Github Actions, điều này cực kỳ phức tạp và kéo dài thời gian build.

### D. Hệ sinh thái đang định hình (Mainly Red Hat)
- `bootc` khởi nguồn từ hệ sinh thái OSTree của Red Hat (CoreOS) nên nó hoạt động tuyệt mỹ trên Fedora, CentOS Stream, RHEL.
- Việc mang `bootc` sang Ubuntu/Debian vẫn còn trong giai đoạn thử nghiệm (như ta đã nghiên cứu ở Docs Status trước đây). Cần chờ `systemd-sysupdate` trưởng thành hơn đối với kiến trúc APT.

### E. Quan sát và Gỡ Lỗi (Debugging / Observability)
- Không thể `dnf install strace tcpdump` trực tiếp trên máy sản xuất do /usr bị khóa.
- Debuggers/Sysadmins phải sử dụng các hộp công cụ riêng biệt biệt lập (toolbox / distrobox container) chứa công cụ debug, sau đó mount chéo vùng nhớ tiến trình vào để xem bệnh. Mindset quản trị hệ thống bị uốn nắn thành Mindset điều hành Kubernetes.

---

## 3. Tổng Kết
Sự hội tụ của Container Tools vào cấp độ Virtual Machine không phải là "làm cho ngầu". Nó là phản ứng sinh tồn bắt buộc của ngành IT trước khối lượng CVE khổng lồ không được phân loại ngày nay. `bootc` là mũi lao tiên phong giải quyết 2 bài toán: **Zero-CVE Compliance** và **Operational Confidence (Tự tin trong Vận Hành)**, đánh đổi lại bằng sự đòi hỏi tính Tuân thủ kỉ luật tuyệt đối (Strict Immutable Architecture) từ đội ngũ Dev và Ops.
