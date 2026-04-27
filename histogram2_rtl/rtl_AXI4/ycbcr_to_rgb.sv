`timescale 1ns / 1ps

module ycbcr_to_rgb (
    input  logic        clk,
    input  logic        rst_n,

    // =====================================================================
    // 上游输入的视频流 (AXI4-Stream Sink)
    // 数据打包格式: [23:16]=Y, [15:8]=Cb, [7:0]=Cr
    // =====================================================================
    input  logic [23:0] s_axis_tdata,
    input  logic        s_axis_tvalid,
    output logic        s_axis_tready,
    input  logic        s_axis_tuser,   // 帧起始 (SOF)
    input  logic        s_axis_tlast,   // 行结束 (EOL)

    // =====================================================================
    // 输出给屏幕的 RGB 视频流 (AXI4-Stream Source)
    // 数据打包格式: [23:16]=R, [15:8]=G, [7:0]=B
    // (相较于输入延迟了 4 拍)
    // =====================================================================
    output logic [23:0] m_axis_tdata,
    output logic        m_axis_tvalid,
    input  logic        m_axis_tready,
    output logic        m_axis_tuser,
    output logic        m_axis_tlast
);

    // =========================================================================
    // 全局流水线控制与反压逻辑
    // =========================================================================
    logic pipe_en;
    assign pipe_en       = m_axis_tready;  // 下游的 ready 信号作为本模块所有流水线寄存器的全局使能 (Global Stall)
    assign s_axis_tready = pipe_en;        // 反压信号直接透传给上游

    // 解析输入数据
    logic [7:0] i_y, i_cb, i_cr;
    assign i_y  = s_axis_tdata[23:16];
    assign i_cb = s_axis_tdata[15:8];
    assign i_cr = s_axis_tdata[7:0];


    // =========================================================================
    // 控制信号同步打拍延迟链 (Data Path Depth = 4)
    // =========================================================================
    // 原代码共有 4 级流水线，因此控制信号需要一个 4-bit 的移位寄存器
    logic [3:0] valid_d, user_d, last_d;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_d <= '0;
            user_d  <= '0;
            last_d  <= '0;
        end else if (pipe_en) begin
            // 只有流水线未被反压时，控制信号才向后推移
            valid_d <= {valid_d[2:0], s_axis_tvalid};
            user_d  <= {user_d[2:0],  s_axis_tuser};
            last_d  <= {last_d[2:0],  s_axis_tlast};
        end
    end


    // =========================================================================
    // Stage 1: 计算色差 (Cb-128) 和 (Cr-128)
    // =========================================================================
    logic [7:0]        y_d1;
    logic signed [8:0] cb_diff; 
    logic signed [8:0] cr_diff;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            y_d1     <= '0;
            cb_diff  <= '0;   
            cr_diff  <= '0;
        end else if (pipe_en) begin
            y_d1     <= i_y; // Y 没参与减法，陪跑一拍
            cb_diff  <= $signed({1'b0, i_cb}) - $signed(9'd128);
            cr_diff  <= $signed({1'b0, i_cr}) - $signed(9'd128);
        end
    end

    // =========================================================================
    // Stage 2: 乘法器阵列
    // =========================================================================
    logic [7:0]         y_d2;
    logic signed [18:0] mult_r, mult_g1, mult_g2, mult_b;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            y_d2    <= '0;
            mult_r  <= '0; mult_g1 <= '0; mult_g2 <= '0; mult_b  <= '0;
        end else if (pipe_en) begin
            y_d2    <= y_d1; // Y 继续陪跑
            mult_r  <= $signed(10'd359) * cr_diff;
            mult_g1 <= $signed(10'd88)  * cb_diff;
            mult_g2 <= $signed(10'd183) * cr_diff;
            mult_b  <= $signed(10'd454) * cb_diff;
        end
    end

    // =========================================================================
    // Stage 3: 加法树
    // =========================================================================
    logic signed [20:0] add_r, add_g, add_b; 

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            add_r <= '0; add_g <= '0; add_b <= '0;
        end else if (pipe_en) begin
            // Y 开始参与计算
            add_r <= $signed({1'b0, y_d2, 8'd0}) + mult_r;
            add_g <= $signed({1'b0, y_d2, 8'd0}) - mult_g1 - mult_g2;
            add_b <= $signed({1'b0, y_d2, 8'd0}) + mult_b;
        end
    end

    // =========================================================================
    // Stage 4: 截断与限幅输出
    // =========================================================================
    logic [7:0] final_r, final_g, final_b;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            final_r <= '0; final_g <= '0; final_b <= '0;
        end else if (pipe_en) begin
            if (add_r < 0)               final_r <= 8'd0;
            else if (add_r > 21'd65280)  final_r <= 8'd255;
            else                         final_r <= add_r[15:8];
            
            if (add_g < 0)               final_g <= 8'd0;
            else if (add_g > 21'd65280)  final_g <= 8'd255;
            else                         final_g <= add_g[15:8];
            
            if (add_b < 0)               final_b <= 8'd0;
            else if (add_b > 21'd65280)  final_b <= 8'd255;
            else                         final_b <= add_b[15:8];
        end
    end

    // =========================================================================
    // 最终 AXI4-Stream 输出打包
    // =========================================================================
    assign m_axis_tdata  = {final_r, final_g, final_b};
    assign m_axis_tvalid = valid_d[3]; 
    assign m_axis_tuser  = user_d[3];
    assign m_axis_tlast  = last_d[3];

endmodule