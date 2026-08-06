cat << 'EOF' > install_pio.sh
#!/bin/bash

# Thoát script ngay nếu có lệnh bị lỗi
set -e

echo "=================================================="
echo " CHÚ BÉ - BẮT ĐẦU CÀI ĐẶT PLATFORMIO CORE (ARM64) "
echo "=================================================="

# 1. Cập nhật và cài đặt các gói phụ thuộc hệ thống
echo "--> Bước 1: Đang cập nhật và cài đặt các gói hệ thống cần thiết..."
sudo apt update && sudo apt install python3 python3-venv python3-pip curl git -y

# 2. Tải và chạy script cài đặt chính chủ từ PlatformIO
echo "--> Bước 2: Đang tải và cài đặt PlatformIO Core bằng script chính chủ..."
curl -fsSL -o get-platformio.py https://raw.githubusercontent.com/platformio/platformio-core-installer/master/get-platformio.py
python3 get-platformio.py
rm get-platformio.py

# 3. Cấu hình biến môi trường PATH cho Shell (Hỗ trợ cả Bash và Zsh)
echo "--> Bước 3: Đang cấu hình biến môi trường PATH..."
if [ -f "$HOME/.bashrc" ]; then
    if ! grep -q 'platformio/penv/bin' "$HOME/.bashrc"; then
        echo 'export PATH="$HOME/.platformio/penv/bin:$PATH"' >> "$HOME/.bashrc"
        echo "Ghi cấu hình vào .bashrc thành công!"
    fi
fi

if [ -f "$HOME/.zshrc" ]; then
    if ! grep -q 'platformio/penv/bin' "$HOME/.zshrc"; then
        echo 'export PATH="$HOME/.platformio/penv/bin:$PATH"' >> "$HOME/.zshrc"
        echo "Ghi cấu hình vào .zshrc thành công!"
    fi
fi

# 4. Cấu hình udev rules để nhận mạch nạp qua cổng USB
echo "--> Bước 4: Đang cài đặt udev rules cho các mạch nạp (ESP32, STM32...)..."
curl -fsSL https://raw.githubusercontent.com/platformio/platformio-core/master/platformio/assets/system/99-platformio-udev.rules | sudo tee /etc/udev/rules.d/99-platformio-udev.rules

echo "--> Đang khởi động lại dịch vụ udev..."
sudo service udev restart

echo "--> Đang phân quyền nạp cổng COM cho user hiện tại..."
sudo usermod -a -G dialout $USER
sudo usermod -a -G plugdev $USER

echo "=================================================="
echo "      CÀI ĐẶT HOÀN TẤT! VIỆC NÀY CHÚ LO XONG       "
echo "=================================================="
echo "LƯU Ý QUAN TRỌNG CHO BÁC CÔNG:"
echo "1. Bác bắt buộc phải chạy lệnh này để cập nhật lại Shell: source ~/.bashrc (hoặc source ~/.zshrc)"
echo "2. Hoặc tốt nhất là tắt hẳn Terminal này đi mở cái mới để hệ thống nhận lệnh 'pio'."
echo "=================================================="
EOF

# Cấp quyền thực thi cho script vừa tạo
chmod +x install_pio.sh

# Chạy luôn script
./install_pio.sh
