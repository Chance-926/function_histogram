`timescale 1ns / 1ps

module histogram_top #(
    parameter int IMG_WIDTH   = 1920,
    parameter int IMG_HEIGHT  = 1080,
    parameter int DIV_LATENCY = 20    // 需与你配置的除法器 IP 延迟保持一致 [cite: 96]
)(
    input  logic        clk,
    input  logic        rst_n,

    // =====================================================================
    // 输入视频流 (AXI4-Stream RGB888)
    // =====================================================================
    input  logic [23:0] s_axis_rgb_tdata,
    input  logic        s_axis_rgb_tvalid,
    output logic        s_axis_rgb_tready,
    input  logic        s_axis_rgb_tuser,   // Start of Frame
    input  logic        s_axis_rgb_tlast,   // End of Line

    // =====================================================================
    // 输出视频流 (AXI4-Stream RGB888)
    // =====================================================================
    output logic [23:0] m_axis_rgb_tdata,
    output logic        m_axis_rgb_tvalid,
    input  logic        m_axis_rgb_tready,
    output logic        m_axis_rgb_tuser,
    output logic        m_axis_rgb_tlast
);

    // =========================================================================
    // 1. 中间总线连线定义 (AXI-Stream)
    // =========================================================================
    
    // rgb_to_ycbcr -> [统计模块 & 映射模块]
    logic [23:0] axis_ycbcr_raw_tdata;
    logic        axis_ycbcr_raw_tvalid;
    logic        axis_ycbcr_raw_tready;
    logic        axis_ycbcr_raw_tuser;
    logic        axis_ycbcr_raw_tlast;

    // lut_map -> ycbcr_to_rgb
    logic [23:0] axis_ycbcr_eq_tdata;
    logic        axis_ycbcr_eq_tvalid;
    logic        axis_ycbcr_eq_tready;
    logic        axis_ycbcr_eq_tuser;
    logic        axis_ycbcr_eq_tlast;

    // =========================================================================
    // 2. 内部控制信号与 BRAM 接口连线
    // =========================================================================
    
    // 统计(Done) -> 生成(Start)
    logic        frame_done_sig; [cite: 157]

    // 统计(RAM) -> 生成(Reader)
    logic        hist_rd_en;
    logic [7:0]  hist_rd_addr;
    logic [23:0] hist_rd_data; [cite: 156, 157]

    // 生成(LUT) -> 映射(Reader)
    logic        lut_ready_sig;
    logic        lut_rd_en;
    logic [7:0]  lut_rd_addr;
    logic [7:0]  lut_rd_data; [cite: 97, 98]

    // =========================================================================
    // 3. 模块实例化
    // =========================================================================

    // --- 阶段 1: 颜色空间转换 (RGB -> YCbCr) ---
    // 输入: RGB888, 输出: YCbCr444 [cite: 219]
    rgb_to_ycbcr u_rgb_to_ycbcr (
        .clk              (clk),
        .rst_n            (rst_n),
        .s_axis_tdata     (s_axis_rgb_tdata),
        .s_axis_tvalid    (s_axis_rgb_tvalid),
        .s_axis_tready    (s_axis_rgb_tready),
        .s_axis_tuser     (s_axis_rgb_tuser),
        .s_axis_tlast     (s_axis_rgb_tlast),
        .m_axis_tdata     (axis_ycbcr_raw_tdata),
        .m_axis_tvalid    (axis_ycbcr_raw_tvalid),
        .m_axis_tready    (axis_ycbcr_raw_tready),
        .m_axis_tuser     (axis_ycbcr_raw_tuser),
        .m_axis_tlast     (axis_ycbcr_raw_tlast)
    );

    
    // --- 关键设计：Broadcaster (并联分发逻辑) ---
    // 为了实现“第N帧统计同时映射”，两个模块必须并联接收同一份数据。
    // 使用“与门”合并 Ready 信号，确保两个从机同步接收。
    logic stat_ready;
    logic map_ready;
    assign axis_ycbcr_raw_tready = stat_ready && map_ready;

    // --- 阶段 2A: 直方图统计 (Sink 模式，旁路侦听) ---
    // 它负责统计“当前帧”的分布情况 [cite: 155]
    histogram_statistic #(
        .IMG_WIDTH        (IMG_WIDTH),
        .IMG_HEIGHT       (IMG_HEIGHT)
    ) u_histogram_statistic (
        .clk              (clk),
        .rst_n            (rst_n),
        .s_axis_tdata     (axis_ycbcr_raw_tdata[23:16]), // 仅统计 Y 分量 [cite: 155]
        .s_axis_tvalid    (axis_ycbcr_raw_tvalid && map_ready), // 只有映射模块也准备好才有效
        .s_axis_tready    (stat_ready),
        .s_axis_tuser     (axis_ycbcr_raw_tuser),
        .i_ram_read_en    (hist_rd_en),
        .i_ram_read_addr  (hist_rd_addr),
        .o_ram_read_data  (hist_rd_data),
        .o_frame_done     (frame_done_sig)
    );

    // --- 阶段 2B: CDF 累加与 LUT 生成 (离线协处理器) ---
    // 在帧间隙利用除法器计算新的映射表 [cite: 96]
    cdf_lut_generator #(
        .IMG_WIDTH        (IMG_WIDTH),
        .IMG_HEIGHT       (IMG_HEIGHT),
        .DIV_LATENCY      (DIV_LATENCY)
    ) u_cdf_lut_generator (
        .clk              (clk),
        .rst_n            (rst_n),
        .i_frame_done     (frame_done_sig),
        .o_hist_rd_en     (hist_rd_en),
        .o_hist_rd_addr   (hist_rd_addr),
        .i_hist_rd_data   (hist_rd_data),
        .i_lut_rd_en      (lut_rd_en),
        .i_lut_rd_addr    (lut_rd_addr),
        .o_lut_rd_data    (lut_rd_data),
        .o_lut_ready      (lut_ready_sig)
    );

    // --- 阶段 2C: 像素映射 (在线流水线) ---
    // 它负责使用“前一帧”生成的 LUT 映射“当前帧”像素 [cite: 197]
    lut_map u_lut_map (
        .clk              (clk),
        .rst_n            (rst_n),
        .i_lut_ready      (lut_ready_sig),
        .o_lut_rd_en      (lut_rd_en),
        .o_lut_rd_addr    (lut_rd_addr),
        .i_lut_rd_data    (lut_rd_data),
        .s_axis_tdata     (axis_ycbcr_raw_tdata),
        .s_axis_tvalid    (axis_ycbcr_raw_tvalid && stat_ready), // 只有统计模块也准备好才有效
        .s_axis_tready    (map_ready),
        .s_axis_tuser     (axis_ycbcr_raw_tuser),
        .s_axis_tlast     (axis_ycbcr_raw_tlast),
        .m_axis_tdata     (axis_ycbcr_eq_tdata),
        .m_axis_tvalid    (axis_ycbcr_eq_tvalid),
        .m_axis_tready    (axis_ycbcr_eq_tready),
        .m_axis_tuser     (axis_ycbcr_eq_tuser),
        .m_axis_tlast     (axis_ycbcr_eq_tlast)
    );

    // --- 阶段 3: 颜色空间还原 (YCbCr -> RGB) ---
    // 输出: RGB888 [cite: 251]
    ycbcr_to_rgb u_ycbcr_to_rgb (
        .clk              (clk),
        .rst_n            (rst_n),
        .s_axis_tdata     (axis_ycbcr_eq_tdata),
        .s_axis_tvalid    (axis_ycbcr_eq_tvalid),
        .s_axis_tready    (axis_ycbcr_eq_tready),
        .s_axis_tuser     (axis_ycbcr_eq_tuser),
        .s_axis_tlast     (axis_ycbcr_eq_tlast),
        .m_axis_tdata     (m_axis_rgb_tdata),
        .m_axis_tvalid    (m_axis_rgb_tvalid),
        .m_axis_tready    (m_axis_rgb_tready),
        .m_axis_tuser     (m_axis_rgb_tuser),
        .m_axis_tlast     (m_axis_rgb_tlast)
    );

endmodule