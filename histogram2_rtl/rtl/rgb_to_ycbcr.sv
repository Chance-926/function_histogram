`timescale 1ns / 1ps

//上一级需要一个转rgb格式的接口

module rgb_to_ycbcr (
    input  logic        clk,
    input  logic        rst_n,

    // =====================================================================
    // Input Stream 
    // =====================================================================
    input  logic        i_vsync,  // 场同步 (标识帧边界)
    input  logic        i_de,     // 数据有效使能 (对应物理层的 HREF)
    input  logic [7:0]  i_r,
    input  logic [7:0]  i_g,
    input  logic [7:0]  i_b,

    // =====================================================================
    // Output Stream
    // =====================================================================
    output logic        o_vsync,
    output logic        o_de,
    output logic [7:0]  o_y,
    output logic [7:0]  o_cb,
    output logic [7:0]  o_cr
);

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
        end else begin 
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
        end else begin
            add_y  <= mult_r_y + mult_g_y + mult_b_y;
            
            sub_cb <= $signed({1'b0, mult_b_cb}) - $signed({1'b0, (mult_r_cb + mult_g_cb)});
            sub_cr <= $signed({1'b0, mult_r_cr}) - $signed({1'b0, (mult_g_cr + mult_b_cr)});
        end
    end

    // =========================================================================
    // Pipeline Stage 3: 移位、补偿 128、溢出截断 
    // =========================================================================
    logic [15:0]        result_y;
    logic signed [16:0] result_cb;
    logic signed [16:0] result_cr;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            result_y  <= '0;
            result_cb <= '0;
            result_cr <= '0;
        end else begin
            result_y  <= add_y >> 8;
            result_cb <= (sub_cb >>> 8) + 17'sd128;
            result_cr <= (sub_cr >>> 8) + 17'sd128;
        end
    end

    assign o_y  = (result_y > 255)  ? 8'd255 : result_y[7:0];
    assign o_cb = (result_cb < 0) ? 8'd0 : ((result_cb > 255) ? 8'd255 : result_cb[7:0]);
    assign o_cr = (result_cr < 0) ? 8'd0 : ((result_cr > 255) ? 8'd255 : result_cr[7:0]);

    
    // =========================================================================
    // 同步信号相位对齐
    // =========================================================================
    
    // 保持相对相位恒定：数据通路深度为 3，控制通路延迟必须严格等于 3
    logic [2:0] vsync_d, de_d;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vsync_d <= '0;
            de_d    <= '0;
        end else begin
            vsync_d <= {vsync_d[1:0], i_vsync};
            de_d    <= {de_d[1:0],    i_de};
        end
    end
    // 输出相位对齐后的同步信号
    assign o_vsync = vsync_d[2];
    assign o_de    = de_d[2];

endmodule