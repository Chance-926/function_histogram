`timescale 1ns / 1ps

//图像总参数待修改
//除法器ip核待接入

module cdf_lut_generator (
    input  logic        clk,
    input  logic        rst_n,

    // =====================================================================
    // 接口 1: 接收上一级 (Histogram RAM) 的控制信号
    // =====================================================================
    input  logic        i_frame_done,    // 触发信号：上一级直方图统计已完成

    // =====================================================================
    // 接口 2: 读取上一级的 Histogram BRAM
    // =====================================================================
    output logic        o_hist_rd_en,    // 读使能
    output logic [7:0]  o_hist_rd_addr,  // 读地址 (0~255)
    input  logic [23:0] i_hist_rd_data,  // 读出的数据 (某灰度级的像素个数)

    // =====================================================================
    // 接口 3: 除法器 IP 核的黑盒接口 (Divider Wrapper)
    // =====================================================================
    output logic        o_div_start,
    output logic [31:0] o_div_dividend,  // 分子常数：255 * 65536
    output logic [31:0] o_div_divisor,   // 分母：TotalPixels - CDF_min
    input  logic        i_div_done,      // IP 核算完了
    input  logic [31:0] i_div_quotient,  // IP 核吐出的结果 (Scale_hw)

    // =====================================================================
    // 接口 4: 向下一级 (映射模块) 提供的 LUT BRAM 读接口
    // (本模块内部包含一个 256x8bit 的 LUT RAM，存最终的映射表)
    // =====================================================================
    input  logic        i_lut_rd_en,
    input  logic [7:0]  i_lut_rd_addr,
    output logic [7:0]  o_lut_rd_data,

    // 状态输出
    output logic        o_lut_ready      // 告诉下一级：LUT 已经全部算好，可以开始映射新一帧
);

    // 图像总像素数参数 (需要修改)
    localparam int TOTAL_PIXELS = 262144; 
    
    // =========================================================================
    // 1. 主控状态机定义
    // =========================================================================
    typedef enum logic [2:0] {
        S_IDLE,       // 0: 等待 i_frame_done 触发
        S_CALC_CDF,   // 1: 遍历 256 个灰度级，累加计算 CDF，并寻找 CDF_min
        S_WAIT_DIV,   // 2: 触发除法器 IP，等待其计算出缩放因子 scale_hw
        S_CALC_LUT,   // 3: 再次遍历 256 个灰度级，执行乘法算出最终 LUT
        S_DONE        // 4: 完成，拉高 o_lut_ready
    } state_t;

    state_t state, next_state;

    // =========================================================================
    // 2. 核心计数器与控制信号
    // =========================================================================

    // 用一个 9-bit 计数器兼顾两个 256 次的循环 (数到 256 意味着循环结束)
    logic [8:0] loop_cnt;  

    // 状态机第一段：状态记忆
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= S_IDLE;
        else        state <= next_state;
    end

    // 状态机第二段：跳转逻辑
    always_comb begin
        next_state = state;
        case (state)
            S_IDLE: 
                if (i_frame_done)          next_state = S_CALC_CDF;
                //t0时i_frame_done被非阻塞赋值，t0NBA时期 next_state被赋新值，t1时state被非阻塞赋值
            
            S_CALC_CDF: 
                // 因为读取 BRAM 有 1 拍延迟，我们要等计数器数到 256 且数据处理完才跳
                // 这里暂定为计数到 256 (后续数据通路会在这里做对齐设计)
                if (loop_cnt == 9'd256)    next_state = S_WAIT_DIV;
            
            S_WAIT_DIV: //等待ip核通过除法计算乘法系数的状态
                if (i_div_done)            next_state = S_CALC_LUT; // IP 核算完了  
            
            S_CALC_LUT: 
                if (loop_cnt == 9'd256)    next_state = S_DONE;
            
            S_DONE:                        
                                           next_state = S_IDLE;
            default:                       next_state = S_IDLE;
        endcase
    end

    // 状态机第三段：计数器调度
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            loop_cnt <= '0;
        end 
        
        else begin
            case (state)
                S_IDLE: begin
                    loop_cnt <= '0; // 待机时清零
                end
                
                S_CALC_CDF, S_CALC_LUT: begin
                    // 在这两个状态下，计数器从 0 跑到 256
                    if (loop_cnt < 9'd256) begin
                        loop_cnt <= loop_cnt + 1'b1;
                    end
                end
                
                S_WAIT_DIV: begin
                    loop_cnt <= '0; // 在等待除法器期间，把计数器清零，为下一次循环做准备
                end
                
                S_DONE: begin
                    loop_cnt <= '0;
                end
            endcase
        end
    end

    // =========================================================================
    // 3. 直方图 BRAM 的读取寻址 
    // =========================================================================

    // 只有在计算 CDF 的状态下，且还没数到 256 时，才发出读请求
    assign o_hist_rd_en   = (state == S_CALC_CDF) && (loop_cnt < 9'd256);
    // 直接用循环计数器的低 8 位作为地址 (0~255)
    assign o_hist_rd_addr = loop_cnt[7:0];

    // =========================================================================
    // 4. 内部 CDF RAM 实例化 (用来临时存储算好的 CDF 值)
    // =========================================================================
    
    // 灰度累计函数，深度 256，位宽 24-bit
    logic [23:0] cdf_ram [0:255];
    
    // =========================================================================
    // 5. 核心数据通路：流水线对齐打拍
    // =========================================================================
    logic [8:0] loop_cnt_d1;  // 延迟 1 拍的计数器，用于对齐 BRAM 读出的数据对应的地址
    logic o_hist_rd_en_d1; // 延迟 1 拍的使能，用于控制在正确的节点开始累加

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            loop_cnt_d1 <= '0;
            o_hist_rd_en_d1 <= '0;
        end 
        else begin       
            loop_cnt_d1 <= loop_cnt;
            o_hist_rd_en_d1 <= o_hist_rd_en;
        end
    end

    // =========================================================================
    // 6. 数据通路 1：累加计算 CDF 与寻找 CDF_min
    // =========================================================================
    logic [31:0] cdf_acc;        // CDF 累加器
    logic [31:0] cdf_min;        // 存储第一帧不为 0 的 CDF 最小值
    logic        found_min;      // 标志位：是否已经找到了 CDF_min
    
    // 组合逻辑加法器：当前累加值 + 刚从 BRAM 读出的像素个数
    logic [31:0] next_cdf;       
    assign next_cdf = cdf_acc + i_hist_rd_data;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cdf_acc   <= '0;
            cdf_min   <= '0;
            found_min <= 1'b0;
        end 
        
        else if (state == S_IDLE) begin
            // 每次新的一帧开始前，清空累加器和标志位
            cdf_acc   <= '0;
            cdf_min   <= '0;
            found_min <= 1'b0;
        end 
        
        else if (state == S_CALC_CDF) begin
            // 当 loop_cnt_d1 在 0~255 的范围内时，说明读出的 i_hist_rd_data 是有效数据
            if ( o_hist_rd_en_d1 && loop_cnt_d1 < 9'd256) begin
                
                // 1. 更新累加器
                cdf_acc <= next_cdf;
                
                // 2. 将结果存入内部的 CDF BRAM (注意写入地址使用的是延迟一拍的 loop_cnt_d1)
                cdf_ram[loop_cnt_d1[7:0]] <= next_cdf[23:0]; 
                
                // 3. 寻找 CDF_min (第一个不为 0 的累加值)
                if (!found_min && (next_cdf > 0)) begin
                    cdf_min   <= next_cdf;
                    found_min <= 1'b1;
                end
            end
        end
    end

    // =========================================================================
    // 7. 数据通路 2：除法器 IP 接口控制
    // =========================================================================
    //！！！待接入elinx的ip核
    assign o_div_dividend = 32'd16711680; // ip核要计算的除法中，分子是常数: 255 * 65536 = 16711680
    assign o_div_divisor  = TOTAL_PIXELS - cdf_min; // ip核要计算的除法中，分母: TotalPixels - CDF_min

    // 生成 i_start 脉冲：只在进入 S_WAIT_DIV 状态的第一个时钟周期拉高一次
    logic state_wait_div_d1;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) 
            state_wait_div_d1 <= 1'b0;
        else        
            state_wait_div_d1 <= (state == S_WAIT_DIV);
    end

    assign o_div_start = (state == S_WAIT_DIV) && (!state_wait_div_d1);
    

    // =========================================================================
    // 8. 内部 LUT RAM 实例化 (用来存储最终的映射表)
    // =========================================================================

    // 灰度映射函数，深度 256，位宽 8-bit (因为映射结果是 0~255 的灰度值)
    logic [7:0] lut_ram [0:255];

    //=========================================================================
    // 9. 数据通路 3：提取 CDF 并执行乘法计算 LUT (修复版)
    // =========================================================================
    // 读取 loop_cnt 号灰度的 CDF RAM 
    logic [23:0] cdf_rd_data;
    always_ff @(posedge clk) begin
        if (state == S_CALC_LUT && loop_cnt < 9'd256) begin
            cdf_rd_data <= cdf_ram[loop_cnt[7:0]];
        end
    end

    // 第一部分：纯组合逻辑 (算数运算，推断 DSP)
    logic [31:0] cur_cdf; 
    logic [63:0] lut_mult_res;  
    logic [7:0]  final_lut_val; 

    always_comb begin
        // 1. 防下溢出减法
        if (cdf_rd_data > cdf_min) 
            cur_cdf = cdf_rd_data - cdf_min;
        else                       
            cur_cdf = '0;

        // 2. 执行乘法 (自动推断 DSP48)
        lut_mult_res = cur_cdf * i_div_quotient;

        // 3. 位移截断与限幅
        if ((lut_mult_res >> 16) > 255) 
            final_lut_val = 8'd255;
        else                            
            final_lut_val = lut_mult_res[23:16]; 
    end

    // 第二部分：纯时序逻辑 (RAM 写入)
    always_ff @(posedge clk) begin
        // 注意：lut_ram 作为 BRAM，不需要也不应该在 rst_n 中复位
        if (state == S_CALC_LUT) begin
            if (loop_cnt_d1 < 9'd256) begin
                lut_ram[loop_cnt_d1[7:0]] <= final_lut_val; // 将算好的值打入 RAM
            end
        end
    end

    // 留给下一级模块读取的接口
    always_ff @(posedge clk) begin
        if (i_lut_rd_en) begin
            o_lut_rd_data <= lut_ram[i_lut_rd_addr];
        end
    end

    // =========================================================================
    // 10. 全局状态输出
    // =========================================================================
    
    logic lut_ready_reg;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lut_ready_reg <= 1'b0;
        end 
        // 当收到上一帧统计完成的脉冲时，意味着马上要开始重写 LUT RAM 了
        // 此时果断拉低 ready 信号，阻塞下游的读取操作 (此时正好处于消隐区)
        else if (i_frame_done) begin
            lut_ready_reg <= 1'b0;
        end
        // 一旦状态机跑完，建表完成，再次拉高
        // 此时消隐区可能还没结束，但表已经更新好了，提前准备好迎接下一帧的有效像素
        else if (state == S_DONE) begin
            lut_ready_reg <= 1'b1; 
        end
    end

    assign o_lut_ready = lut_ready_reg;

endmodule