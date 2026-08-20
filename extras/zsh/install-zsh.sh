#!/bin/bash

# 1. KIỂM TRA QUYỀN CHẠY SCRIPT (BẮT BỆNH ROOT)
if [ "$EUID" -eq 0 ]; then
    echo "========================================================="
    echo " LỖI NGHIÊM TRỌNG: BÁC ĐANG CHẠY SCRIPT BẰNG QUYỀN ROOT! "
    echo "========================================================="
    echo "Chú đã dặn rồi, không dùng 'sudo ./install_zsh.sh' nhé."
    echo "Hãy thoát quyền root ra và chạy lại bằng lệnh bình thường:"
    echo "  ./install_zsh.sh"
    exit 1
fi

# Định nghĩa rõ ràng thông tin user hiện tại
USER_HOME="$HOME"
USER_NAME="$USER"

echo "================================================="
echo "   CHÚ BÉ: SCRIPT ZSH & P10K KHÔNG LO LỖI QUYỀN  "
echo "================================================="

# 2. Cài đặt các gói từ APT hệ thống
echo "--> Bước 1: Cài đặt Zsh, Git, Curl từ hệ thống..."
sudo apt update
sudo apt install zsh git curl -y

# 3. XỬ LÝ Ổ KHÓA QUYỀN ROOT CỦA THƯ MỤC CŨ (NẾU CÓ)
echo "--> Bước 2: Kiểm tra và giải phóng quyền sở hữu thư mục..."
if [ -d "$USER_HOME/.oh-my-zsh" ]; then
    echo "Phát hiện thư mục cũ, đang ép chuyển sở hữu về cho user $USER_NAME..."
    sudo chown -R "$USER_NAME:$USER_NAME" "$USER_HOME/.oh-my-zsh"
    # Dọn sạch để cài mới cho đồng bộ, không lo lỗi file nát
    rm -rf "$USER_HOME/.oh-my-zsh"
fi

# 4. Tải bộ khung Oh My Zsh chính chủ
echo "--> Bước 3: Tải bộ khung Oh My Zsh sạch sẽ..."
git clone https://github.com/ohmyzsh/ohmyzsh.git "$USER_HOME/.oh-my-zsh"

# 5. Tải Theme Powerlevel10k
echo "--> Bước 4: Tải theme Powerlevel10k..."
mkdir -p "$USER_HOME/.oh-my-zsh/custom/themes"
git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$USER_HOME/.oh-my-zsh/custom/themes/powerlevel10k"

# 6. Tải các Plugins gợi ý lệnh và tô màu câu lệnh
echo "--> Bước 5: Tải các plugins mở rộng (autosuggestions, highlighting)..."
mkdir -p "$USER_HOME/.oh-my-zsh/custom/plugins"
git clone https://github.com/zsh-users/zsh-autosuggestions "$USER_HOME/.oh-my-zsh/custom/plugins/zsh-autosuggestions"
git clone https://github.com/zsh-users/zsh-syntax-highlighting.git "$USER_HOME/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting"

# 7. Khởi tạo file .zshrc chuẩn đét từ đầu
echo "--> Bước 6: Khởi tạo file cấu hình .zshrc mới tinh..."
cat << 'EOF' > "$USER_HOME/.zshrc"
# Đường dẫn Oh My Zsh
export ZSH="$HOME/.oh-my-zsh"

# Cấu hình Theme Powerlevel10k thần thánh
ZSH_THEME="powerlevel10k/powerlevel10k"

# Bật thông báo cập nhật định kỳ không làm phiền
zstyle ':omz:update' mode reminder
zstyle ':omz:update' frequency 13

# Danh sách Plugins hoạt động (Có cả extract giải nén cực ngon)
plugins=(
    git 
    zsh-autosuggestions 
    zsh-syntax-highlighting 
    extract
)

# Kích hoạt Oh My Zsh
source $ZSH/oh-my-zsh.sh

# Đồng bộ đường dẫn PlatformIO (pio) cho bác code vi điều khiển
if [ -d "$HOME/.platformio/penv/bin" ]; then
    export PATH="$HOME/.platformio/penv/bin:$PATH"
fi

# Giữ lại đường dẫn bin cục bộ của user
export PATH="$HOME/.local/bin:$PATH"
EOF

# Đảm bảo file .zshrc cũng thuộc quyền sở hữu của user thường
sudo chown "$USER_NAME:$USER_NAME" "$USER_HOME/.zshrc"

# 8. Đổi Shell mặc định sang Zsh cho user
echo "--> Bước 7: Đổi shell mặc định của hệ thống sang Zsh..."
sudo chsh -s $(which zsh) "$USER_NAME"

echo "================================================="
echo "      ĐÃ XỬ LÝ XONG NGON LÀNH BÁC CÔNG ƠI!       "
echo " Bác tắt hẳn Terminal mở lại để hưởng thụ nhé!  "
echo "================================================="
