`timescale 1ns / 1ps

module lut_map (
    input  logic        clk,
    input  logic        rst_n,

    // =====================================================================
    // LUT 状态控制 (来自上一级 cdf_lut_generator)
    // =====================================================================
    input  logic        i_lut_ready, 

    // =====================================================================
    // LUT BRAM 读接口
    // =====================================================================
    output logic        o_lut_rd_en,
    output logic [7:0]  o_lut_rd_addr,
    input  logic [7:0]  i_lut_rd_data, 

    // =====================================================================
    // 上游输入的视频流 (AXI4-Stream Sink)
    // tdata 数据格式: [23:16]=Y, [15:8]=Cb, [7:0]=Cr
    // =====================================================================
    input  logic [23:0] s_axis_tdata,
    input  logic        s_axis_tvalid,
    output logic        s_axis_tready,
    input  logic        s_axis_tuser,   // 帧起始 (SOF)
    input  logic        s_axis_tlast,   // 行结束 (EOL)

    // =====================================================================
    // 输出给下游的视频流 
    // =====================================================================
    output logic [23:0] m_axis_tdata,
    output logic        m_axis_tvalid,
    input  logic        m_axis_tready,
    output logic        m_axis_tuser,
    output logic        m_axis_tlast
);

    // =========================================================================
    // 1. 全局流水线控制与反压逻辑
    // =========================================================================
    logic pipe_en;
    assign pipe_en       = m_axis_tready;// 下游的 ready 信号直接作为全局使能 
    assign s_axis_tready = pipe_en;     // 直接将反压信号透传给上游，实现协议握手环路


    // =========================================================================
    // 2. 防撕裂机制：帧级锁存 LUT Ready 信号
    // =========================================================================
    // 在 AXI-Stream 中，当新一帧的第一个像素 (tuser) 握手成功时，刷新查表使能。
    logic lut_ready_frame;
    logic is_fst_pixel;
    
    assign is_fst_pixel = s_axis_tvalid && s_axis_tready && s_axis_tuser;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lut_ready_frame <= 1'b0;
        end else if (is_fst_pixel) begin
            // 在每一帧的开头，锁存一次准备好的标志，保证一整帧内映射表不变
            lut_ready_frame <= i_lut_ready;
        end
    end


    // =========================================================================
    // Pipeline Stage 0: 查表请求与第一级信号打拍
    // =========================================================================
    logic [7:0] in_y;
    assign in_y = s_axis_tdata[23:16];

    // 发起 BRAM 读请求
    // 核心细节：当流水线被反压 (pipe_en=0) 时，强行拉低 o_lut_rd_en。
    // Xilinx/亿海微的 BRAM 在 en 为 0 时，输出端会保持上一个周期的旧值不丢失。
    assign o_lut_rd_en   = s_axis_tvalid && pipe_en;
    assign o_lut_rd_addr = in_y;  

    // 对齐打拍流水线 (延迟 1 拍，命名遵循 conv.sv 风格)
    logic [23:0] in_data_d1;
    logic        in_valid_d1;
    logic        in_user_d1;
    logic        in_last_d1;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            in_data_d1  <= '0;
            in_valid_d1 <= 1'b0;
            in_user_d1  <= 1'b0;
            in_last_d1  <= 1'b0;
        end else if (pipe_en) begin
            // 只有当流水线没有被反压时，数据才往后流动
            in_data_d1  <= s_axis_tdata;
            in_valid_d1 <= s_axis_tvalid;
            in_user_d1  <= s_axis_tuser;
            in_last_d1  <= s_axis_tlast;
        end
    end


    // =========================================================================
    // Pipeline Stage 1: 接收查表结果，完成重组输出
    // =========================================================================
    
    logic [7:0] y_eq;
    
    // BRAM 的 i_lut_rd_data 正好在此时有效。如果表建好了就用新表，否则输出原图
    assign y_eq = lut_ready_frame ? i_lut_rd_data : in_data_d1[23:16];

    // 组合输出给下游
    assign m_axis_tdata  = {y_eq, in_data_d1[15:0]}; // {均衡化后的 Y, 陪跑的 Cb, 陪跑的 Cr}
    assign m_axis_tvalid = in_valid_d1;
    assign m_axis_tuser  = in_user_d1;
    assign m_axis_tlast  = in_last_d1;

endmodule