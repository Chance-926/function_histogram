# =========================================================
# 脚本：simulate.do
# 描述：ModelSim / Questasim 自动化仿真脚本
# =========================================================

# 1. 退出之前的仿真并清理工作区
quit -sim
if {[file exists work]} {
    vdel -lib work -all
}

# 2. 建立并映射工作库
vlib work
vmap work work

# 3. 编译 RTL 源码 (注意路径是相对于当前的 sim 文件夹)
# -sv 告诉编译器使用 SystemVerilog 语法
vlog -sv ../rtl/elinx_divider_32b.sv
vlog -sv ../rtl/rgb_to_ycbcr.sv
vlog -sv ../rtl/histogram_statistic.sv
vlog -sv ../rtl/cdf_lut_generator.sv
vlog -sv ../rtl/lut_map_and_ycbcr2rgb.sv
vlog -sv ../rtl/isp_histogram_top.sv

# 4. 编译 Testbench
vlog -sv ../tb/tb_isp_histogram_top.sv

# 5. 启动仿真
# -voptargs=+acc 参数极其重要：防止仿真器为了提速把内部信号优化掉，导致你看不到波形
vsim -voptargs=+acc work.tb_isp_histogram_top

# 6. 添加顶层关键波形到波形窗口
add wave -divider "System Signals"
add wave -radix binary sim:/tb_isp_histogram_top/clk
add wave -radix binary sim:/tb_isp_histogram_top/rst_n

add wave -divider "Input Camera Stream (Frame 1 & 2)"
add wave -radix binary sim:/tb_isp_histogram_top/i_cam_vsync
add wave -radix binary sim:/tb_isp_histogram_top/i_cam_hsync
add wave -radix binary sim:/tb_isp_histogram_top/i_cam_de
add wave -radix unsigned sim:/tb_isp_histogram_top/i_cam_r

add wave -divider "Output Display Stream (Only Frame 2 saved)"
add wave -radix binary sim:/tb_isp_histogram_top/o_disp_vsync
add wave -radix binary sim:/tb_isp_histogram_top/o_disp_hsync
add wave -radix binary sim:/tb_isp_histogram_top/o_disp_de
add wave -radix unsigned sim:/tb_isp_histogram_top/o_disp_r

# 7. 运行仿真
# 512*512 双帧大约需要 6ms 的仿真时间
run 6ms