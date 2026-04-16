`timescale 1ns / 1ps

module ycbcr_to_rgb (
    input  logic        clk,
    input  logic        rst_n,

    // 从上一级模块输入的视频流
    input  logic        i_vsync, 
    input  logic        i_de,
    input  logic [7:0]  i_y,
    input  logic [7:0]  i_cb,
    input  logic [7:0]  i_cr,

    // 输出给屏幕的 RGB 视频流 (相较于输入延迟了 4 拍)
    output logic        o_vsync, 
    output logic        o_de,
    output logic [7:0]  o_r,
    output logic [7:0]  o_g,
    output logic [7:0]  o_b
);

    // =========================================================================
    // Stage 1: 计算色差 (Cb-128) 和 (Cr-128)
    // =========================================================================
    logic       vsync_d1, de_d1;
    logic [7:0] y_d1;
    logic signed [8:0] cb_diff; 
    logic signed [8:0] cr_diff;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vsync_d1 <= 1'b0; de_d1 <= 1'b0; y_d1 <= '0;
            cb_diff  <= '0;   cr_diff <= '0;
        end else begin
            vsync_d1 <= i_vsync; 
            de_d1    <= i_de;
            y_d1     <= i_y; // Y 没参与减法，陪跑一拍
            
            cb_diff <= $signed({1'b0, i_cb}) - $signed(9'd128);
            cr_diff <= $signed({1'b0, i_cr}) - $signed(9'd128);
        end
    end

    // =========================================================================
    // Stage 2: 乘法器阵列
    // =========================================================================
    logic       vsync_d2, de_d2;
    logic [7:0] y_d2;
    logic signed [18:0] mult_r, mult_g1, mult_g2, mult_b;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vsync_d2 <= 1'b0; de_d2 <= 1'b0; y_d2 <= '0;
            mult_r <= '0; mult_g1 <= '0; mult_g2 <= '0; mult_b <= '0;
        end else begin
            vsync_d2 <= vsync_d1; 
            de_d2    <= de_d1;
            y_d2     <= y_d1; // Y 继续陪跑
            
            mult_r  <= $signed(10'd359) * cr_diff; 
            mult_g1 <= $signed(10'd88)  * cb_diff;
            mult_g2 <= $signed(10'd183) * cr_diff;
            mult_b  <= $signed(10'd454) * cb_diff;
        end
    end

    // =========================================================================
    // Stage 3: 加法树
    // =========================================================================
    logic       vsync_d3, de_d3;
    logic signed [20:0] add_r, add_g, add_b; 

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vsync_d3 <= 1'b0; de_d3 <= 1'b0;
            add_r <= '0; add_g <= '0; add_b <= '0;
        end else begin
            vsync_d3 <= vsync_d2; 
            de_d3    <= de_d2;
            
            // Y 开始参与计算
            add_r <= $signed({1'b0, y_d2, 8'd0}) + mult_r;
            add_g <= $signed({1'b0, y_d2, 8'd0}) - mult_g1 - mult_g2;
            add_b <= $signed({1'b0, y_d2, 8'd0}) + mult_b;
        end
    end

    // =========================================================================
    // Stage 4: 截断与限幅输出
    // =========================================================================
    logic       vsync_d4, de_d4;
    logic [7:0] final_r, final_g, final_b;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vsync_d4 <= 1'b0; de_d4 <= 1'b0;
            final_r <= '0; final_g <= '0; final_b <= '0;
        end else begin
            vsync_d4 <= vsync_d3; 
            de_d4    <= de_d3;
            
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

    assign o_vsync = vsync_d4;
    assign o_de    = de_d4;
    assign o_r     = final_r;
    assign o_g     = final_g;
    assign o_b     = final_b;

endmodule