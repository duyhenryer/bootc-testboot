# Deep Dive: Điểm Hạn Chế Của `bootc`

Là một DevOps giỏi, bạn phải vạch ra rõ ràng ranh giới và những mặt trái của kiến trúc Containerized OS này trước lãnh đạo, phòng trường hợp "đụng tường":

## 1. Sự xung đột với "Legacy Apps" (Ứng dụng cũ)
- **Filesystem Read-Only:** Đây là rào cản chí mạng. `bootc` khóa cứng (Read-Only) thư mục `/usr` và gần như toàn bộ hệ điều hành. Chỉ chừa lại `/etc` (cho config) và `/var` (cho dữ liệu) là ghi được (Read-Write).
- Nếu các ứng dụng cũ (như một số phần mềm ngân hàng/core-banking) có thói quen "bạ đâu ghi đấy", ví dụ như đổ log thẳng vào thư mục cài đặt gốc `/opt/myapp/logs`, ứng dụng đó sẽ lập tức **crash** khi chạy trên bootc. Vượt qua điều này đòi hỏi phải quy chuẩn hóa ứng dụng hoặc tận dụng `systemd-tmpfiles`.

## 2. Quản Lý Trạng Thái Cấu Hình (State Drift & Configuration Management)
- **Không có "Fix Nóng" (Hot-fixes):** Giả sử 2h sáng server bị lỗi mạng, Sysadmin SSH vào máy ảo, chạy lệnh sửa file gốc hệ thống để cứu app. Sáng hôm sau khi máy reboot hoặc tiến hành update image bootc mới, bản sửa lỗi "chạy bằng tay" đó sẽ **bốc hơi**, hệ thống phục hồi lại nguyên trạng Container Image trên GitHub.
- **Phải thay đổi Mindset:** Mọi thay đổi về cấu hình HĐH phải được commit dạng mã (Infrastructure as Code) vào `Containerfile`, build lại CI và chờ máy chủ pull về. Tính cục bộ bị loại bỏ hoàn toàn.

## 3. Sự Đứt Gãy Ở Quản Lý Drivers / Kernel Modules (Đặc biệt GPU)
- Đối với Máy ảo chạy thiết bị ngoại vi phức tạp (Ví dụ kẹp NVIDIA GPUs để chạy AI), việc nạp kernel modules của bên thứ 3 vào bootc là một cơn ác mộng (Out-of-Tree modules).
- Bạn phải biên dịch driver (kmod pull, akmods) trực tiếp vào bên trong Container Image trên luồng Github Actions, điều này cực kỳ phức tạp và kéo dài thời gian build.

## 4. Hệ sinh thái đang định hình (Mainly Red Hat)
- `bootc` khởi nguồn từ hệ sinh thái OSTree của Red Hat (CoreOS) nên nó hoạt động tuyệt mỹ trên Fedora, CentOS Stream, RHEL.
- Việc mang `bootc` sang Ubuntu/Debian vẫn còn trong giai đoạn thử nghiệm (như ta đã nghiên cứu ở Docs Status trước đây). Cần chờ `systemd-sysupdate` trưởng thành hơn đối với kiến trúc APT.

## 5. Quan sát và Gỡ Lỗi (Debugging / Observability)
- Không thể `dnf install strace tcpdump` trực tiếp trên máy sản xuất do /usr bị khóa.
- Debuggers/Sysadmins phải sử dụng các hộp công cụ riêng biệt biệt lập (toolbox / distrobox container) chứa công cụ debug, sau đó mount chéo vùng nhớ tiến trình vào để xem bệnh. Mindset quản trị hệ thống bị uốn nắn thành Mindset điều hành Kubernetes.
