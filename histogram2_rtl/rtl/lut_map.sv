`timescale 1ns / 1ps

module video_lut_mapping (
    input  logic        clk,
    input  logic        rst_n,

    // LUT 状态控制
    input  logic        i_lut_ready, 

    // LUT BRAM 读接口
    output logic        o_lut_rd_en,
    output logic [7:0]  o_lut_rd_addr,
    input  logic [7:0]  i_lut_rd_data, 

    // 上游输入的视频流
    input  logic        i_vsync, 
    input  logic        i_de,
    input  logic [7:0]  i_y,
    input  logic [7:0]  i_cb,
    input  logic [7:0]  i_cr,

    // 输出给下游的视频流 (延迟了 1 拍)
    output logic        o_vsync, 
    output logic        o_de,
    output logic [7:0]  o_y_eq, // 均衡化后的 Y
    output logic [7:0]  o_cb,   // 陪跑对齐的 Cb
    output logic [7:0]  o_cr    // 陪跑对齐的 Cr
);

    // 1. 防撕裂：帧级锁存 LUT Ready 信号
    logic vsync_prev;
    logic lut_ready_frame;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vsync_prev      <= 1'b0;
            lut_ready_frame <= 1'b0;
        end else begin
            vsync_prev <= i_vsync;
            if (vsync_prev == 1'b1 && i_vsync == 1'b0) begin//消隐区结束
                lut_ready_frame <= i_lut_ready; 
            end
        end
    end

    // =========================================================================
    // Pipeline Stage 0: 查表请求与第一级信号打拍
    // =========================================================================
    // 2. 发起 BRAM 读请求 (无延迟)
    assign o_lut_rd_en   = i_de; 
    assign o_lut_rd_addr = i_y;  

    // 3. 对齐打拍流水线 (延迟 1 拍)
    logic       vsync_d1, de_d1;
    logic [7:0] cb_d1, cr_d1, y_d1;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vsync_d1 <= 1'b0; de_d1 <= 1'b0;
            cb_d1    <= '0;   cr_d1 <= '0;   y_d1 <= '0;
        end else begin
            vsync_d1 <= i_vsync;
            de_d1    <= i_de;
            cb_d1    <= i_cb;    
            cr_d1    <= i_cr;    
            y_d1     <= i_y; // 备份原图 Y
        end
    end

    // =========================================================================
    // Pipeline Stage 1: 接收 Y_eq，计算 (Cb-128) 和 (Cr-128)
    // =========================================================================

    // 4. 输出赋值
    assign o_vsync = vsync_d1;
    assign o_de    = de_d1;
    assign o_cb    = cb_d1;
    assign o_cr    = cr_d1;
    // BRAM 的 i_lut_rd_data 正好在此时有效，与 d1 信号完美对齐
    assign o_y_eq  = lut_ready_frame ? i_lut_rd_data : y_d1; 

endmodule