import cv2
import numpy as np
import os

# =========================================================
# 脚本：hex_to_img.py (本地后处理版)
# =========================================================

# 自动获取当前 Python 脚本所在的绝对目录
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

# 假设你已经把服务器算好的 txt 下载到了当前脚本的同级目录
input_txt_path = os.path.join(SCRIPT_DIR, "img_output_hex.txt") 
output_img_path = os.path.join(SCRIPT_DIR, "result_image.png")

# 必须与你仿真的图像尺寸保持一致
WIDTH = 512
HEIGHT = 512

def hex_to_img():
    # 检查文件是否下载到位
    if not os.path.exists(input_txt_path):
        print(f"❌ 找不到输出文件: {input_txt_path}")
        print("💡 请确认你已经从服务器把 img_output_hex.txt 下载到了本脚本所在的文件夹！")
        return

    # 创建一个空的 numpy 数组，数据类型为 uint8 (0-255)
    img_rgb = np.zeros((HEIGHT, WIDTH, 3), dtype=np.uint8)

    print("⏳ 正在将 Hex 文本还原为图像...")
    with open(input_txt_path, "r") as f:
        lines = f.readlines()
        
        # 防御性编程：检查输出的像素数量是否足够
        if len(lines) < WIDTH * HEIGHT:
            print(f"⚠️ 警告: txt 文件只有 {len(lines)} 行，不足一帧({WIDTH*HEIGHT}像素)，图片可能不完整！")
            
        pixel_idx = 0
        for y in range(HEIGHT):
            for x in range(WIDTH):
                if pixel_idx < len(lines):
                    hex_str = lines[pixel_idx].strip()
                    # 确保读取的字符串有效，防止空行报错
                    if len(hex_str) >= 6:
                        r = int(hex_str[0:2], 16)
                        g = int(hex_str[2:4], 16)
                        b = int(hex_str[4:6], 16)
                        img_rgb[y, x] = [r, g, b]
                    pixel_idx += 1

    # 转回 OpenCV 习惯的 BGR 格式并保存
    img_bgr = cv2.cvtColor(img_rgb, cv2.COLOR_RGB2BGR)
    cv2.imwrite(output_img_path, img_bgr)
    print(f"🎉 成功！图像已保存为: {output_img_path}")

if __name__ == "__main__":
    hex_to_img()