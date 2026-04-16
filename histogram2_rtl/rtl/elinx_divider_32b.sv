`timescale 1ns / 1ps

// =========================================================================
// 模块：elinx_divider_32b (仿真用行为级除法器模型)
// 描述：用于在 Testbench 中替代特定厂商的除法器 IP 核。
//       模拟了真实 IP 核的多周期延迟 (Latency) 特性。
// =========================================================================
module elinx_divider_32b #(
    parameter integer LATENCY = 16  // 模拟真实除法器 IP 的流水线延迟周期数
)(
    input  logic        clk,
    input  logic        rst_n,
    
    input  logic        i_start,    // 触发信号 (脉冲)
    input  logic [31:0] i_dividend, // 被除数 (分子)
    input  logic [31:0] i_divisor,  // 除数 (分母)
    
    output logic        o_done,     // 计算完成信号 (脉冲)
    output logic [31:0] o_quotient  // 商
);

    // 内部流水线寄存器定义
    logic [31:0] dividend_pipe [0:LATENCY-1];
    logic [31:0] divisor_pipe  [0:LATENCY-1];
    logic        valid_pipe    [0:LATENCY-1];

    integer i;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < LATENCY; i = i + 1) begin
                dividend_pipe[i] <= '0;
                divisor_pipe[i]  <= '0;
                valid_pipe[i]    <= 1'b0;
            end
            o_done     <= 1'b0;
            o_quotient <= '0;
        end else begin
            // --------------------------------------------------
            // Stage 0: 接收输入 (当 i_start 有效时捕获数据)
            // --------------------------------------------------
            dividend_pipe[0] <= i_dividend;
            divisor_pipe[0]  <= i_divisor;
            valid_pipe[0]    <= i_start;

            // --------------------------------------------------
            // Stage 1 to LATENCY-1: 数据在流水线中向后传递，模拟延迟
            // --------------------------------------------------
            for (i = 1; i < LATENCY; i = i + 1) begin
                dividend_pipe[i] <= dividend_pipe[i-1];
                divisor_pipe[i]  <= divisor_pipe[i-1];
                valid_pipe[i]    <= valid_pipe[i-1];
            end

            // --------------------------------------------------
            // Stage Output: 在最后一个周期输出除法结果
            // --------------------------------------------------
            o_done <= valid_pipe[LATENCY-1];
            if (valid_pipe[LATENCY-1]) begin
                // 使用仿真器的除法运算符直接计算结果
                // 防御性编程：防止除数为 0 导致仿真报错 (X态)
                if (divisor_pipe[LATENCY-1] != 0) begin
                    o_quotient <= dividend_pipe[LATENCY-1] / divisor_pipe[LATENCY-1];
                end else begin
                    o_quotient <= 32'hFFFF_FFFF; // 除以 0 返回最大值
                end
            end else begin
                o_done <= 1'b0;
            end
        end
    end

endmodule