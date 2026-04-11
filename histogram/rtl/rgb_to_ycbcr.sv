`timescale 1ns / 1ps

module rgb_to_ycbcr (
    input  logic        clk,
    input  logic        rst_n,

    // Input Stream (DVP timing style)
    input  logic        i_vsync,  // 场同步
    input  logic        i_hsync,  // 行同步
    input  logic        i_de,     // 数据有效使能 (Data Enable)
    input  logic [7:0]  i_r,
    input  logic [7:0]  i_g,
    input  logic [7:0]  i_b,

    // Output Stream
    output logic        o_vsync,
    output logic        o_hsync,
    output logic        o_de,
    output logic [7:0]  o_y,
    output logic [7:0]  o_cb,
    output logic [7:0]  o_cr
);

    // =========================================================================
    // Pipeline Stage 1: 乘法 (Multiplication)
    // =========================================================================
    // 定义 16-bit 寄存器存储乘法结果 (8-bit 像素 * 8-bit 系数 = 最多 16-bit)
    logic [15:0] mult_r_y, mult_g_y, mult_b_y;
    logic [15:0] mult_r_cb, mult_g_cb, mult_b_cb;
    logic [15:0] mult_r_cr, mult_g_cr, mult_b_cr;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mult_r_y  <= '0; mult_g_y  <= '0; mult_b_y  <= '0;
            mult_r_cb <= '0; mult_g_cb <= '0; mult_b_cb <= '0;
            mult_r_cr <= '0; mult_g_cr <= '0; mult_b_cr <= '0;
        end else if (i_de) begin // 只有在数据有效时才进行计算，节省功耗
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

    // =========================================================================
    // Pipeline Stage 2: 加减法树 (Adder Tree)
    // =========================================================================
    logic [15:0] add_y;
    logic [15:0] sub_cb;
    logic [15:0] sub_cr;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            add_y  <= '0;
            sub_cb <= '0;
            sub_cr <= '0;
        end else begin
            // 按照定点化公式进行加减
            add_y  <= mult_r_y + mult_g_y + mult_b_y;
            // Cb = -43R - 85G + 128B -> 128B - (43R + 85G)
            sub_cb <= mult_b_cb - (mult_r_cb + mult_g_cb);
            // Cr = 128R - 107G - 21B -> 128R - (107G + 21B)
            sub_cr <= mult_r_cr - (mult_g_cr + mult_b_cr);
        end
    end

    // =========================================================================
    // Pipeline Stage 3: 移位、补偿 128、溢出截断 (Shift & Clip)
    // =========================================================================
    // 扩展位数以防止加 128 时溢出
    logic [15:0] result_y, result_cb, result_cr;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            result_y  <= '0;
            result_cb <= '0;
            result_cr <= '0;
        end else begin
            // >> 8 相当于取高 8 位。我们补上 128 的偏移量
            result_y  <= add_y >> 8;
            result_cb <= (sub_cb >> 8) + 16'd128;
            result_cr <= (sub_cr >> 8) + 16'd128;
        end
    end

    // 输出赋值并进行范围截断 (Clipping to 0-255)
    assign o_y  = (result_y  > 255) ? 8'd255 : result_y[7:0];
    assign o_cb = (result_cb > 255) ? 8'd255 : (result_cb[15] ? 8'd0 : result_cb[7:0]); // 包含对负数的防御
    assign o_cr = (result_cr > 255) ? 8'd255 : (result_cr[15] ? 8'd0 : result_cr[7:0]);

    // =========================================================================
    // 同步信号延迟 (Synchronization Delay Shift Registers)
    // =========================================================================
    
    // 数据打了几拍，控制信号就必须打几拍！这里数据延迟了 “3 个 Clock”。
    logic [2:0] vsync_d, hsync_d, de_d;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vsync_d <= '0;
            hsync_d <= '0;
            de_d    <= '0;
        end else begin
            vsync_d <= {vsync_d[1:0], i_vsync};
            hsync_d <= {hsync_d[1:0], i_hsync};
            de_d    <= {de_d[1:0],    i_de};
        end
    end

    // 输出对齐后的同步信号
    assign o_vsync = vsync_d[2];
    assign o_hsync = hsync_d[2];
    assign o_de    = de_d[2];

endmodule