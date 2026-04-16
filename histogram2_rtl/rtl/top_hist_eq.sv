`timescale 1ns / 1ps

module top_hist_eq (
    input  logic        clk,
    input  logic        rst_n,

    // =====================================================================
    // Video Stream Input (来自 OV5640 接口逻辑)
    // =====================================================================
    input  logic        i_vsync, 
    input  logic        i_hsync, // 仅透传或预留，本算法不严格依赖 HSYNC
    input  logic        i_de,
    input  logic [7:0]  i_r,
    input  logic [7:0]  i_g,
    input  logic [7:0]  i_b,

    // =====================================================================
    // Video Stream Output (去往 VGA/HDMI 接口逻辑)
    // =====================================================================
    output logic        o_vsync,
    output logic        o_de,
    output logic [7:0]  o_r,
    output logic [7:0]  o_g,
    output logic [7:0]  o_b
);

    // =========================================================================
    // 内部连线声明 (Internal Signals)
    // =========================================================================
    // 1. RGB 转 YCbCr 后的视频流
    logic        ycbcr_vsync, ycbcr_de;
    logic [7:0]  ycbcr_y, ycbcr_cb, ycbcr_cr;

    // 2. 直方图统计与 LUT 生成之间的控制与数据交互
    logic        frame_done_pulse;
    logic        hist_rd_en;
    logic [7:0]  hist_rd_addr;
    logic [23:0] hist_rd_data;

    // 3. LUT 生成与除法器之间的握手信号
    logic        div_start;
    logic [31:0] div_dividend;
    logic [31:0] div_divisor;
    logic        div_done;
    logic [31:0] div_quotient;

    // 4. LUT 生成与视频映射之间的交互
    logic        lut_ready;
    logic        lut_rd_en;
    logic [7:0]  lut_rd_addr;
    logic [7:0]  lut_rd_data;

    // 5. 映射后的视频流
    logic        eq_vsync, eq_de;
    logic [7:0]  eq_y, eq_cb, eq_cr;


    // =========================================================================
    // 模块实例化 (Module Instantiations)
    // =========================================================================

    // 1. 色彩空间转换: RGB -> YCbCr
    rgb_to_ycbcr u_rgb_to_ycbcr (
        .clk        (clk),
        .rst_n      (rst_n),
        .i_vsync    (i_vsync),
        .i_de       (i_de),
        .i_r        (i_r),
        .i_g        (i_g),
        .i_b        (i_b),
        .o_vsync    (ycbcr_vsync),
        .o_de       (ycbcr_de),
        .o_y        (ycbcr_y),
        .o_cb       (ycbcr_cb),
        .o_cr       (ycbcr_cr)
    );

    // 2. 直方图统计 (抓取 Y 分量进行像素分布统计)
    histogram_statistic u_hist_stat (
        .clk             (clk),
        .rst_n           (rst_n),
        .i_vsync         (ycbcr_vsync),
        .i_hsync         (i_hsync),     // 透传输入
        .i_de            (ycbcr_de),
        .i_y             (ycbcr_y),
        // 给下游读 RAM 的接口
        .i_ram_read_en   (hist_rd_en),
        .i_ram_read_addr (hist_rd_addr),
        .o_ram_read_data (hist_rd_data),
        .o_frame_done    (frame_done_pulse)
    );

    // 3. CDF 计算与映射表 (LUT) 生成
    cdf_lut_generator u_cdf_lut_gen (
        .clk             (clk),
        .rst_n           (rst_n),
        .i_frame_done    (frame_done_pulse),
        // 读取上游直方图 RAM 接口
        .o_hist_rd_en    (hist_rd_en),
        .o_hist_rd_addr  (hist_rd_addr),
        .i_hist_rd_data  (hist_rd_data),
        // 挂载除法器 IP 接口
        .o_div_start     (div_start),
        .o_div_dividend  (div_dividend),
        .o_div_divisor   (div_divisor),
        .i_div_done      (div_done),
        .i_div_quotient  (div_quotient),
        // 供下游映射读取的 LUT RAM 接口
        .i_lut_rd_en     (lut_rd_en),
        .i_lut_rd_addr   (lut_rd_addr),
        .o_lut_rd_data   (lut_rd_data),
        // 状态输出
        .o_lut_ready     (lut_ready)
    );

    // 4. 模拟/IP 除法器实例化 (未来上板替换为中科亿海微底层 IP)
    elinx_divider_32b #(
        .LATENCY(16)
    ) u_divider (
        .clk        (clk),
        .rst_n      (rst_n),
        .i_start    (div_start),
        .i_dividend (div_dividend),
        .i_divisor  (div_divisor),
        .o_done     (div_done),
        .o_quotient (div_quotient)
    );

    // 5. 视频像素查表映射 (应用 LUT 到 Y 分量)
    video_lut_mapping u_video_mapping (
        .clk           (clk),
        .rst_n         (rst_n),
        .i_lut_ready   (lut_ready),
        // LUT BRAM 读接口
        .o_lut_rd_en   (lut_rd_en),
        .o_lut_rd_addr (lut_rd_addr),
        .i_lut_rd_data (lut_rd_data),
        // 视频流输入
        .i_vsync       (ycbcr_vsync),
        .i_de          (ycbcr_de),
        .i_y           (ycbcr_y),
        .i_cb          (ycbcr_cb),
        .i_cr          (ycbcr_cr),
        // 视频流输出
        .o_vsync       (eq_vsync),
        .o_de          (eq_de),
        .o_y_eq        (eq_y), // 均衡化后的 Y
        .o_cb          (eq_cb),
        .o_cr          (eq_cr)
    );

    // 6. 色彩空间转换: YCbCr -> RGB
    ycbcr_to_rgb u_ycbcr_to_rgb (
        .clk        (clk),
        .rst_n      (rst_n),
        .i_vsync    (eq_vsync),
        .i_de       (eq_de),
        .i_y        (eq_y),
        .i_cb       (eq_cb),
        .i_cr       (eq_cr),
        .o_vsync    (o_vsync),
        .o_de       (o_de),
        .o_r        (o_r),
        .o_g        (o_g),
        .o_b        (o_b)
    );

endmodule