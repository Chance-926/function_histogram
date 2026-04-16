import cv2
import numpy as np
import os

# =========================================================================
# 脚本：img_to_hex.py
# 描述：读取测试图片，缩放到 1000x1000，并生成 Testbench 可读的 Hex 文本
# =========================================================================

# 1. 你的原始测试图片路径 (请随便找一张对比度低、偏暗或偏亮的图片)
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

# 拼接出图片和输出文本的绝对路径
# 这样无论你在哪里运行脚本，它都能精准找到同目录下的文件
input_img_path = os.path.join(SCRIPT_DIR, "test_image.png") 
output_txt_path = os.path.join(SCRIPT_DIR, "img_input_hex.txt")

# 2. 定义测试分辨率
WIDTH = 512
HEIGHT = 512

def generate_hex_file():
    if not os.path.exists(input_img_path):
        print(f"❌ 找不到输入图片: {input_img_path}")
        return

    # 读取图像
    img = cv2.imread(input_img_path)
    # 强制缩放为你设定的测试分辨率
    img_resized = cv2.resize(img, (WIDTH, HEIGHT))
    
    # OpenCV 默认读取格式是 BGR，我们转换为 RGB
    img_rgb = cv2.cvtColor(img_resized, cv2.COLOR_BGR2RGB)

    print(f"✅ 图片读取并缩放成功，尺寸: {WIDTH}x{HEIGHT}")
    print("⏳ 正在生成 Hex 文本文件，请稍候...")

    with open(output_txt_path, "w") as f:
        # 逐行逐列遍历像素
        for y in range(HEIGHT):
            for x in range(WIDTH):
                # 获取 RGB 像素值
                r, g, b = img_rgb[y, x]
                # 格式化为 6位 16进制字符串，例如 "FF8800"，并写入文件
                f.write(f"{r:02x}{g:02x}{b:02x}\n")

    print(f"🎉 转换完成！已生成文件: {output_txt_path}")
    print(f"总计写入 {WIDTH * HEIGHT} 个像素数据。")

if __name__ == "__main__":
    generate_hex_file()