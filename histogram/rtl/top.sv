`timescale 1ns / 1ps

// =========================================================================
// 模块：isp_histogram_top (直方图均衡化顶层系统)
// 描述：将所有子模块例化并连接，形成完整的视频流水线
// =========================================================================
module isp_histogram_top (
    input  logic        clk,           // 系统时钟 (如 100MHz)
    input  logic        rst_n,         // 全局异步复位，低电平有效

    // --------------------------------------------------
    // 输入接口 (连接摄像头 DVP 接收模块)
    // --------------------------------------------------
    input  logic        i_cam_vsync,   // 摄像头场同步
    input  logic        i_cam_hsync,   // 摄像头行同步
    input  logic        i_cam_de,      // 摄像头数据有效
    input  logic [7:0]  i_cam_r,       // 原始红
    input  logic [7:0]  i_cam_g,       // 原始绿
    input  logic [7:0]  i_cam_b,       // 原始蓝

    // --------------------------------------------------
    // 输出接口 (连接 HDMI/VGA 发送模块)
    // --------------------------------------------------
    output logic        o_disp_vsync,  // 显示器场同步
    output logic        o_disp_hsync,  // 显示器行同步
    output logic        o_disp_de,     // 显示器数据有效
    output logic [7:0]  o_disp_r,      // 均衡化后的红
    output logic [7:0]  o_disp_g,      // 均衡化后的绿
    output logic [7:0]  o_disp_b       // 均衡化后的蓝
);

    // =========================================================================
    // 内部连线 (Wires) 声明
    // =========================================================================

    // 1. [第一阶段 -> 后续阶段] 的 YCbCr 视频流连线
    logic        w_ycbcr_vsync, w_ycbcr_hsync, w_ycbcr_de;
    logic [7:0]  w_y, w_cb, w_cr;

    // 2. [第二阶段 -> 第三阶段] 的控制与直方图读取连线
    logic        w_frame_done;
    logic        w_hist_rd_en;
    logic [7:0]  w_hist_rd_addr;
    logic [23:0] w_hist_rd_data;

    // 3. [第三阶段 <-> 除法器 IP] 的握手与数据连线
    logic        w_div_start;
    logic [31:0] w_div_dividend, w_div_divisor;
    logic        w_div_done;
    logic [31:0] w_div_quotient;

    // 4. [第三阶段 -> 第四阶段] 的控制与 LUT 读取连线
    logic        w_lut_ready;
    logic        w_lut_rd_en;
    logic [7:0]  w_lut_rd_addr;
    logic [7:0]  w_lut_rd_data;

    // =========================================================================
    // 模块例化 (建立黑盒，并用上面的线把它们连起来)
    // =========================================================================

    // --------------------------------------------------
    // 第一阶段: RGB 到 YCbCr 转换 (流水线起点)
    // --------------------------------------------------
    rgb_to_ycbcr u_rgb_to_ycbcr (
        .clk        (clk),
        .rst_n      (rst_n),
        
        .i_vsync    (i_cam_vsync),
        .i_hsync    (i_cam_hsync),
        .i_de       (i_cam_de),
        .i_r        (i_cam_r),
        .i_g        (i_cam_g),
        .i_b        (i_cam_b),
        
        .o_vsync    (w_ycbcr_vsync),
        .o_hsync    (w_ycbcr_hsync),
        .o_de       (w_ycbcr_de),
        .o_y        (w_y),
        .o_cb       (w_cb),
        .o_cr       (w_cr)
    );

    // --------------------------------------------------
    // 第二阶段: 直方图统计 (支路 A: 监听视频流)
    // --------------------------------------------------
    histogram_statistic u_histogram_statistic (
        .clk              (clk),
        .rst_n            (rst_n),
        
        // 接收视频流 (仅需要亮度和同步信号)
        .i_vsync          (w_ycbcr_vsync),
        .i_hsync          (w_ycbcr_hsync),
        .i_de             (w_ycbcr_de),
        .i_y              (w_y),
        
        // 提供给第三阶段的 BRAM 读接口
        .i_ram_read_en    (w_hist_rd_en),
        .i_ram_read_addr  (w_hist_rd_addr),
        .o_ram_read_data  (w_hist_rd_data),
        
        // 通知第三阶段: 一帧统计完毕
        .o_frame_done     (w_frame_done)
    );

    // --------------------------------------------------
    // 第三阶段: CDF 与 LUT 生成中枢 (在消隐区疯狂运算)
    // --------------------------------------------------
    cdf_lut_generator u_cdf_lut_generator (
        .clk              (clk),
        .rst_n            (rst_n),
        
        // 接收第二阶段的触发并读取直方图
        .i_frame_done     (w_frame_done),
        .o_hist_rd_en     (w_hist_rd_en),
        .o_hist_rd_addr   (w_hist_rd_addr),
        .i_hist_rd_data   (w_hist_rd_data),
        
        // 连接到外部的除法器 IP 核 
        .o_div_start      (w_div_start),
        .o_div_dividend   (w_div_dividend),
        .o_div_divisor    (w_div_divisor),
        .i_div_done       (w_div_done),
        .i_div_quotient   (w_div_quotient),
        
        // 提供给第四阶段的 LUT BRAM 读接口
        .i_lut_rd_en      (w_lut_rd_en),
        .i_lut_rd_addr    (w_lut_rd_addr),
        .o_lut_rd_data    (w_lut_rd_data),
        
        // 通知第四阶段: 新的 LUT 映射表已备好
        .o_lut_ready      (w_lut_ready)
    );

    // --------------------------------------------------
    // 除法器 IP 核 (亿灵思 IP 例化占位)
    // --------------------------------------------------
    elinx_divider_32b u_scale_divider (
        .clk              (clk),
        .rst_n            (rst_n),
        .i_start          (w_div_start),
        .i_dividend       (w_div_dividend),
        .i_divisor        (w_div_divisor),
        .o_done           (w_div_done),
        .o_quotient       (w_div_quotient)
    );

    // --------------------------------------------------
    // 第四阶段: 查表映射与逆转换 (主干道终点)
    // --------------------------------------------------
    lut_map_and_ycbcr2rgb u_lut_mapper (
        .clk              (clk),
        .rst_n            (rst_n),
        
        // 接收 LUT 就绪信号并主动去查表
        .i_lut_ready      (w_lut_ready),
        .o_lut_rd_en      (w_lut_rd_en),
        .o_lut_rd_addr    (w_lut_rd_addr),
        .i_lut_rd_data    (w_lut_rd_data),
        
        // 接收主干道传来的 YCbCr 视频流
        .i_vsync          (w_ycbcr_vsync),
        .i_hsync          (w_ycbcr_hsync),
        .i_de             (w_ycbcr_de),
        .i_y              (w_y),
        .i_cb             (w_cb),
        .i_cr             (w_cr),
        
        // 最终输出到屏幕
        .o_vsync          (o_disp_vsync),
        .o_hsync          (o_disp_hsync),
        .o_de             (o_disp_de),
        .o_r              (o_disp_r),
        .o_g              (o_disp_g),
        .o_b              (o_disp_b)
    );

endmodule