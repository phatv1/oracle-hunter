# Oracle Hunter

Worker Bash/Python thử tạo VPS Oracle theo lịch, có jitter và backoff khi bị
throttle. Chạy trên FadeHost thì máy cá nhân có thể shutdown.

## Deploy trên FadeHost

1. Đưa source lên `https://github.com/phatv1/oracle-hunter`.
2. Trong FadeHost: **Apps → Host an app → Something else → Your own repository**.
3. Repository: `https://github.com/phatv1/oracle-hunter`; branch: `main`.
4. Language: **Python**; Start command: **`python main.py`**; Build command để trống.
   FadeHost cài `requirements.txt` tự động.
5. Điền các biến môi trường bên dưới vào phần Environment variables, rồi Deploy.
6. Xem console: cần thấy `OCI authentication OK`, sau đó kiểm tra instance và
   bắt đầu scheduler. Khi đó dừng bản retry trên máy cá nhân để tránh chạy trùng.

Không cần systemd, nohup, cron, cổng public hoặc web address cho worker này.
Chỉ tạo một app và chạy một bản worker.

FadeHost Free có 256 MB RAM. OCI CLI cần được kiểm tra thực tế với giới hạn này;
nếu console báo OOM, chuyển lên gói có nhiều RAM hơn. Free cho phép outbound
HTTPS 443 mà Oracle API và Telegram sử dụng. Nếu chọn paid và muốn runtime
được đóng gói đầy đủ, chọn Build mode **Dockerfile**; repo có Dockerfile sẵn.

Tài liệu chính thức:
[App Hosting](https://fadehost.com/docs/app-hosting/),
[Firewall](https://fadehost.com/docs/app-firewall/).

## Biến môi trường bắt buộc

| Tên | Giá trị |
| --- | --- |
| `OCI_USER_OCID` | `user` trong OCI config đang dùng |
| `OCI_TENANCY_OCID` | `tenancy` trong OCI config |
| `OCI_FINGERPRINT` | `fingerprint` trong OCI config |
| `OCI_PRIVATE_KEY_B64` | Base64 của API private key PEM mà `key_file` trỏ tới |
| `SSH_PUBLIC_KEY_B64` | Base64 của SSH public key để đăng nhập VPS Oracle |

Base64 là cách truyền file qua biến môi trường, không phải mã hóa bảo mật.
Chỉ nhập các giá trị vào Environment variables của FadeHost, không commit
private key hay file `oracle-vps.env` vào GitHub.

Trên macOS, copy trực tiếp base64 vào clipboard, thay đường dẫn cho đúng:

```bash
base64 < ~/.oci/oci_api_key.pem | tr -d '\n' | pbcopy
# Paste vào OCI_PRIVATE_KEY_B64 trên FadeHost

base64 < ~/.ssh/oracle-vps.pub | tr -d '\n' | pbcopy
# Paste vào SSH_PUBLIC_KEY_B64 trên FadeHost
```

SSH private key để đăng nhập VPS Oracle giữ trên máy cá nhân; worker chỉ cần
SSH public key. API private key của Oracle là file khác.
Nếu API private key có passphrase, thêm `OCI_KEY_PASSPHRASE`.

## Cấu hình Oracle

Nhập các biến dưới đây theo `oracle-vps.env` hiện tại. Ví dụ không chứa secret:

```dotenv
REGION=ap-singapore-1
INSTANCE_NAME=oracle-vps
HOSTNAME_LABEL=oracle-vps
VCN_NAME=main-vcn
SUBNET_NAME=public-subnet
A1_OCPUS=1
A1_MEMORY_GBS=6
A1_INTERVAL_SECONDS=3000
A1_JITTER_SECONDS=300
E2_PROBABILITY=0.30
E2_DELAY_AFTER_A1_SECONDS=1200
E2_JITTER_SECONDS=300
```

Thêm `COMPARTMENT_OCID` nếu dùng compartment riêng; để trống dùng root tenancy.
VCN/subnet phải có sẵn và khớp tên. Các biến lịch khác trong
`lib/config.sh` cũng có thể được đặt trực tiếp trên FadeHost.
Muốn nhận Telegram, thêm `TELEGRAM_BOT_TOKEN` và `TELEGRAM_CHAT_ID`.
Thông báo gọi trực tiếp Telegram API, không tải script bên ngoài.

Không nhập đường dẫn macOS vào FadeHost. `main.py` tự tạo OCI config và key
trong thư mục tạm riêng, quyền file 600, rồi truyền đường dẫn tới Bash.
Worker dùng profile DEFAULT với API key, không đọc `oracle-vps.env` local.

## Khi thành công và khi restart

Khi tạo được VPS hoặc thấy instance đã tồn tại, hunter dừng các yêu cầu Oracle
và worker chờ idle để tránh vòng lặp restart của hosting. Có thể Stop app trong
FadeHost để ngừng worker hoàn toàn. Nếu deploy/restart, script kiểm tra instance
đã tồn tại trước khi tiếp tục thử tạo; giữ nguyên INSTANCE_NAME.
Khi script lỗi, worker thoát khác 0 để FadeHost có thể restart.
Không đặt MAX_LOOPS nếu muốn thử liên tục; mặc định là 0.

## Đưa source lên GitHub

Thư mục này đã có `.gitignore` loại env, key, log và virtualenv. Nếu GitHub CLI
chưa đăng nhập, chạy `gh auth login`. Sau đó:

```bash
git add .gitignore .dockerignore Dockerfile README.md requirements.txt main.py \
  retry-oracle-vps.sh oracle-vpsctl.sh oracle-vps.env.example lib tests
git diff --cached --stat
git commit -m "Set up Oracle hunter worker for FadeHost"
git push -u origin main
```

## Chạy local

Lệnh cũ vẫn dùng cấu hình local:

```bash
./oracle-vpsctl.sh start
./oracle-vpsctl.sh tail
./oracle-vpsctl.sh stop
```

Kiểm tra launcher, không gọi Oracle API:

```bash
python3 -m unittest discover -s tests -v
```
