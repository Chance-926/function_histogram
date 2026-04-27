`timescale 1ns / 1ps

module rgb_to_ycbcr (
    input  logic        clk,
    input  logic        rst_n,

    // =====================================================================
    // 上游输入的视频流 (AXI4-Stream Sink)
    // 默认数据打包格式: [23:16]=R, [15:8]=G, [7:0]=B
    // =====================================================================
    input  logic [23:0] s_axis_tdata,
    input  logic        s_axis_tvalid,
    output logic        s_axis_tready,
    input  logic        s_axis_tuser,   // 帧起始 (SOF)
    input  logic        s_axis_tlast,   // 行结束 (EOL)

    // =====================================================================
    // 输出给下游的视频流 (AXI4-Stream Source)
    // 数据打包格式: [23:16]=Y, [15:8]=Cb, [7:0]=Cr
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
    assign pipe_en       = m_axis_tready;   // 下游的 ready 信号作为本模块所有流水线寄存器的全局使能 (Global Stall)
    assign s_axis_tready = pipe_en;         // 本模块是纯流水线，没有内部缓冲，反压信号直接透传给上游

    // 解析输入数据
    logic [7:0] i_r, i_g, i_b;
    assign i_r = s_axis_tdata[23:16];
    assign i_g = s_axis_tdata[15:8];
    assign i_b = s_axis_tdata[7:0];


    // =========================================================================
    // 控制信号同步打拍延迟链 (Data Path Depth = 3)
    // =========================================================================
    // 在 AXI-Stream 中，valid, user, last 必须与数据严丝合缝地对齐
    logic [2:0] valid_d, user_d, last_d;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_d <= '0;
            user_d  <= '0;
            last_d  <= '0;
        end else if (pipe_en) begin
            // 只有流水线未被反压时，控制信号才向后推移
            valid_d <= {valid_d[1:0], s_axis_tvalid};
            user_d  <= {user_d[1:0],  s_axis_tuser};
            last_d  <= {last_d[1:0],  s_axis_tlast};
        end
    end


    // =========================================================================
    // Pipeline Stage 1: 乘法 
    // =========================================================================
    logic [15:0] mult_r_y, mult_g_y, mult_b_y;
    logic [15:0] mult_r_cb, mult_g_cb, mult_b_cb;
    logic [15:0] mult_r_cr, mult_g_cr, mult_b_cr;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mult_r_y  <= '0; mult_g_y  <= '0; mult_b_y  <= '0;
            mult_r_cb <= '0; mult_g_cb <= '0; mult_b_cb <= '0;
            mult_r_cr <= '0; mult_g_cr <= '0; mult_b_cr <= '0;
        end else if (pipe_en) begin 
            // 无论 valid 是否有效，流水线只受 pipe_en (反压) 控制
            // 无效数据自然会被最后输出的 valid_d[2] 屏蔽，这样可以简化逻辑
            mult_r_y  <= i_r * 8'd77;
            mult_g_y  <= i_g * 8'd150;
            mult_b_y  <= i_b * 8'd29;

            mult_r_cb <= i_r * 8'd43;
            mult_g_cb <= i_g * 8'd85;
            mult_b_cb <= i_b * 8'd128;

            mult_r_cr <= i_r * 8'd128;
            mult_g_cr <= i_g * 8'd107;
            mult_b_cr <= i_b * 8'd21;
        end
    end

    //=========================================================================
    // Pipeline Stage 2: 加减法树 
    // =========================================================================
    logic [15:0] add_y;
    logic signed [16:0] sub_cb;
    logic signed [16:0] sub_cr;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            add_y  <= '0;
            sub_cb <= '0;
            sub_cr <= '0;
        end else if (pipe_en) begin
            add_y  <= mult_r_y + mult_g_y + mult_b_y;
            sub_cb <= $signed({1'b0, mult_b_cb}) - $signed({1'b0, (mult_r_cb + mult_g_cb)});
            sub_cr <= $signed({1'b0, mult_r_cr}) - $signed({1'b0, (mult_g_cr + mult_b_cr)});
        end
    end

    // =========================================================================
    // Pipeline Stage 3: 移位、补偿 128、溢出截断准备
    // =========================================================================
    logic [15:0]        result_y;
    logic signed [16:0] result_cb;
    logic signed [16:0] result_cr;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            result_y  <= '0;
            result_cb <= '0;
            result_cr <= '0;
        end else if (pipe_en) begin
            result_y  <= add_y >> 8;
            result_cb <= (sub_cb >>> 8) + 17'sd128;
            result_cr <= (sub_cr >>> 8) + 17'sd128;
        end
    end

    // =========================================================================
    // Stage 3 组合逻辑尾部：饱和截断与最终 AXI4-Stream 输出打包
    // =========================================================================
    logic [7:0] o_y, o_cb, o_cr;

    assign o_y  = (result_y > 255)  ? 8'd255 : result_y[7:0];
    assign o_cb = (result_cb < 0) ? 8'd0 : ((result_cb > 255) ? 8'd255 : result_cb[7:0]);
    assign o_cr = (result_cr < 0) ? 8'd0 : ((result_cr > 255) ? 8'd255 : result_cr[7:0]);

    // 输出信号赋值
    assign m_axis_tdata  = {o_y, o_cb, o_cr};
    assign m_axis_tvalid = valid_d[2]; // 严格对应 Pipeline 的第 3 级延迟
    assign m_axis_tuser  = user_d[2];
    assign m_axis_tlast  = last_d[2];

endmodule