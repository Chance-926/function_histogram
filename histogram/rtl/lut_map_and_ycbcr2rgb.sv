`timescale 1ns / 1ps

module lut_map_and_ycbcr2rgb (
    input  logic        clk,
    input  logic        rst_n,

    // =====================================================================
    // 接口 1: 状态控制信号
    // =====================================================================
    // 来自上一级模块的就绪信号。
    // 0: 第一帧还没算完 LUT，不要查表； 1: LUT 就绪，开始查表均衡化
    input  logic        i_lut_ready, 

    // =====================================================================
    // 接口 2: 读取 LUT BRAM 的接口
    // =====================================================================
    output logic        o_lut_rd_en,
    output logic [7:0]  o_lut_rd_addr,
    input  logic [7:0]  i_lut_rd_data, // 读出的均衡化后的亮度 Y_eq ？？？

    // =====================================================================
    // 接口 3: 从上一级 (或摄像头流) 输入的 YCbCr 数据
    // =====================================================================
    input  logic        i_vsync, //场同步
    input  logic        i_hsync, //行同步
    input  logic        i_de,
    input  logic [7:0]  i_y,
    input  logic [7:0]  i_cb,
    input  logic [7:0]  i_cr,

    // =====================================================================
    // 接口 4: 最终输出到屏幕的 RGB 视频流
    // =====================================================================
    output logic        o_vsync, //场同步
    output logic        o_hsync, //行同步
    output logic        o_de,
    output logic [7:0]  o_r,
    output logic [7:0]  o_g,
    output logic [7:0]  o_b
);

    // =========================================================================
    // Pipeline Stage 0: 查表请求与第一级信号打拍
    // =========================================================================
    logic       vsync_d1, hsync_d1, de_d1;
    logic [7:0] cb_d1, cr_d1;
    logic [7:0] y_d1; // 备份一份原始的 Y，以防 LUT 还没准备好

    // 发出 LUT BRAM 读请求
    assign o_lut_rd_en   = i_de; // YCbCr 数据装备好了，请求 LUT BRAM
    assign o_lut_rd_addr = i_y; //把输入的 Y 作为地址传给 LUT BRAM 

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vsync_d1 <= 1'b0; hsync_d1 <= 1'b0; de_d1 <= 1'b0;
            cb_d1    <= '0;   cr_d1    <= '0;   y_d1  <= '0;
        end else begin// LUT BRAM 吐出数据在下一个周期，所以延时1拍
            vsync_d1 <= i_vsync;
            hsync_d1 <= i_hsync; 
            de_d1    <= i_de;
            
            cb_d1    <= i_cb;    
            cr_d1    <= i_cr;    
            y_d1     <= i_y;
        end
    end

    // =========================================================================
    // Pipeline Stage 1: 接收 Y_eq，计算 (Cb-128) 和 (Cr-128)
    // =========================================================================
    logic       vsync_d2, hsync_d2, de_d2;
    logic [7:0] y_eq;
    
    // 【关键点】：声明有符号变量 (signed)，位宽扩展到 9-bit 以防止减法溢出
    logic signed [8:0] cb_diff; 
    logic signed [8:0] cr_diff;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vsync_d2 <= 1'b0; hsync_d2 <= 1'b0; de_d2 <= 1'b0;
            y_eq     <= '0;   cb_diff  <= '0;   cr_diff <= '0;
        end 
        
        else begin
            vsync_d2 <= vsync_d1; 
            hsync_d2 <= hsync_d1; 
            de_d2 <= de_d1;
            
            // 鲁棒性设计 (Bypass): 如果 LUT 还没算好(比如系统刚开机第一帧)，就用原始亮度 Y
            y_eq <= i_lut_ready ? i_lut_rd_data : y_d1; // 如果LUT 就绪，读出的均衡化后的亮度 Y_eq
            
            // 计算有符号差值。注意：要把 8-bit 无符号的 Cb 强制扩展为 9-bit 正数，再去减 128
            cb_diff <= $signed({1'b0, cb_d1}) - $signed(9'd128);
            cr_diff <= $signed({1'b0, cr_d1}) - $signed(9'd128);
        end
    end

    // =========================================================================
    // Pipeline Stage 2: 乘法器阵列 (定点化系数: * 256)
    // =========================================================================
    // 定点化公式推导:
    // R = Y + 1.402*Cr_diff         ->  R = Y + (359 * Cr_diff) >> 8
    // G = Y - 0.344*Cb_diff - 0.714*Cr_diff -> G = Y - (88 * Cb_diff) - (183 * Cr_diff) >> 8
    // B = Y + 1.772*Cb_diff         ->  B = Y + (454 * Cb_diff) >> 8

    logic       vsync_d3, hsync_d3, de_d3;
    logic [7:0] y_eq_d3;
    
    // 乘法结果必须也是有符号的，10-bit系数 * 9-bit差值，最多需要 19-bit 寄存器
    logic signed [18:0] mult_r;
    logic signed [18:0] mult_g1, mult_g2;
    logic signed [18:0] mult_b;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vsync_d3 <= 1'b0; hsync_d3 <= 1'b0; de_d3 <= 1'b0; y_eq_d3 <= '0;
            mult_r <= '0; mult_g1 <= '0; mult_g2 <= '0; mult_b <= '0;
        end 
        
        else begin
            vsync_d3 <= vsync_d2; 
            hsync_d3 <= hsync_d2; 
            de_d3 <= de_d2;
            
            y_eq_d3  <= y_eq; // 把 Y_eq 往下传
            
            // 调用 FPGA 内部的 DSP 资源进行有符号乘法，计算公式中的乘法部分，g通道有两项
            mult_r  <= $signed(10'd359) * cr_diff; 
            mult_g1 <= $signed(10'd88)  * cb_diff;
            mult_g2 <= $signed(10'd183) * cr_diff;
            mult_b  <= $signed(10'd454) * cb_diff;
        end
    end

    // =========================================================================
    // Pipeline Stage 3: 加法树 (把 Y_eq 放大 256 倍后进行加减)
    // =========================================================================
    logic       vsync_d4, hsync_d4, de_d4;
    logic signed [20:0] add_r, add_g, add_b; // 再次扩展位宽防止加法溢出

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vsync_d4 <= 1'b0; hsync_d4 <= 1'b0; de_d4 <= 1'b0;
            add_r <= '0; add_g <= '0; add_b <= '0;
        end 
        
        else begin
            vsync_d4 <= vsync_d3; 
            hsync_d4 <= hsync_d3; 
            de_d4 <= de_d3;
            
            // 把无符号的 Y_eq 变成有符号，并左移 8 位 (相当于乘以 256)
            add_r <= $signed({1'b0, y_eq_d3, 8'd0}) + mult_r;
            add_g <= $signed({1'b0, y_eq_d3, 8'd0}) - mult_g1 - mult_g2;
            add_b <= $signed({1'b0, y_eq_d3, 8'd0}) + mult_b;
        end
    end

    // =========================================================================
    // Pipeline Stage 4: 截断、越界限制 (Clipping) 与最终输出
    // =========================================================================
    logic       vsync_d5, hsync_d5, de_d5;
    logic [7:0] final_r, final_g, final_b;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vsync_d5 <= 1'b0; hsync_d5 <= 1'b0; de_d5 <= 1'b0;
            final_r <= '0; final_g <= '0; final_b <= '0;
        end 
        
        else begin
            vsync_d5 <= vsync_d4; 
            hsync_d5 <= hsync_d4; 
            de_d5 <= de_d4;
            
            // 右移 8 位相当于取 [15:8]。
            // 必须处理两种溢出：1. 小于 0 (负数变为0); 2. 大于 255 (变为255)
            // 255 * 256 = 65280
            
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

    // 最终输出赋值
    assign o_vsync = vsync_d5;
    assign o_hsync = hsync_d5;
    assign o_de    = de_d5;
    assign o_r     = final_r;
    assign o_g     = final_g;
    assign o_b     = final_b;

endmodule