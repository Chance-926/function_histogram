`timescale 1ns / 1ps

module cdf_lut_generator #(
    parameter int IMG_WIDTH   = 1920,
    parameter int IMG_HEIGHT  = 1080,
    parameter int DIV_LATENCY = 20   
)(
    input  logic        clk,
    input  logic        rst_n,

    // =====================================================================
    // 接口 1: 接收上一级的触发信号
    // =====================================================================
    input  logic        i_frame_done,    

    // =====================================================================
    // 接口 2: 读取上一级的 Histogram BRAM
    // =====================================================================
    output logic        o_hist_rd_en,    
    output logic [7:0]  o_hist_rd_addr,  
    input  logic [23:0] i_hist_rd_data,  

    // =====================================================================
    // 接口 3: 向下一级 (映射模块) 提供的 LUT BRAM 读接口
    // =====================================================================
    input  logic        i_lut_rd_en,
    input  logic [7:0]  i_lut_rd_addr,
    output logic [7:0]  o_lut_rd_data,

    // 状态输出
    output logic        o_lut_ready      
);

    localparam int TOTAL_PIXELS = IMG_WIDTH * IMG_HEIGHT;

    // =========================================================================
    // 1. 主控状态机定义
    // =========================================================================
    typedef enum logic [2:0] {
        S_IDLE,       
        S_CALC_CDF,   // 遍历 256 个灰度级，累加 CDF 并寻找 CDF_min
        S_WAIT_DIV,   // 等待固定延迟的流水线除法器 IP 吐出结果
        S_CALC_LUT,   // 再次遍历 256 个灰度级，算数乘法并写入最终 LUT
        S_DONE        // 完成，拉高 o_lut_ready
    } state_t;

    state_t state, next_state;

    logic [8:0] loop_cnt;       // 0-256 的通用循环计数器
    logic [7:0] timer_div;      // 专用于等待除法器 Latency 的计数器

    //状态机跳转逻辑
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= S_IDLE;
        else        state <= next_state;
    end

    always_comb begin
        next_state = state;
        case (state)
            S_IDLE: 
                if (i_frame_done)               next_state = S_CALC_CDF;
            
            S_CALC_CDF: 
                // 数到 256，意味着 0-255 地址发完，且最后一笔数据被累加
                if (loop_cnt == 9'd256)         next_state = S_WAIT_DIV;
            
            S_WAIT_DIV: 
                // 等固定时间除法器流水线出结果
                if (timer_div == DIV_LATENCY)   next_state = S_CALC_LUT;
            
            S_CALC_LUT: 
                //数到 256，最后一笔数据被累加，增加了 2 拍流水线，等待乘法算完
                if (loop_cnt == 9'd258)         next_state = S_DONE;
            
            S_DONE:                        
                                                next_state = S_IDLE;
                
            default:                            next_state = S_IDLE;
        endcase
    end

    // 计数器更新逻辑
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            loop_cnt  <= '0;
            timer_div <= '0;
        end else begin
            case (state)
               S_CALC_CDF: begin
                    if (loop_cnt < 9'd256) loop_cnt <= loop_cnt + 1'b1;
                    timer_div <= '0;
                end
                S_CALC_LUT: begin
                    if (loop_cnt < 9'd258) loop_cnt <= loop_cnt + 1'b1;
                    timer_div <= '0;
                end
                S_WAIT_DIV: begin
                    loop_cnt  <= '0;
                    timer_div <= timer_div + 1'b1;
                end
                default: begin
                    loop_cnt  <= '0;
                    timer_div <= '0;
                end
            endcase
        end
    end

    // =========================================================================
    // 2. CDF统计
    // =========================================================================

    // 1. Y分布统计 BRAM 的读取，CDF RAM 实例化，流水线对齐打拍
    (* ram_style = "distributed" *) logic [23:0] cdf_ram [0:255];

    assign o_hist_rd_en   = (state == S_CALC_CDF) && (loop_cnt < 9'd256);
    assign o_hist_rd_addr = loop_cnt[7:0];  //发送地址
    
    // 读数据伴随的打拍使能信号
    logic       o_hist_rd_en_d1; // 延迟 1 拍的使能，用于控制在正确的节点开始累加
    logic [8:0] loop_cnt_d1, loop_cnt_d2, loop_cnt_d3; //统计CDF要用到d1，统计LUT要用到d3
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            o_hist_rd_en_d1 <= 1'b0;
            loop_cnt_d1   <= '0;
            loop_cnt_d2     <= '0;
            loop_cnt_d3     <= '0;
        end else begin       
            o_hist_rd_en_d1 <= o_hist_rd_en;
            loop_cnt_d1     <= loop_cnt;
            loop_cnt_d2     <= loop_cnt_d1;
            loop_cnt_d3     <= loop_cnt_d2;
        end
    end

    // 2. 数据通路 1：累加 CDF 与寻找 CDF_min
    logic [31:0] cdf_acc;       // CDF 累加器
    logic [31:0] cdf_min;       // 存储第一帧不为 0 的 CDF 最小值    
    logic        found_min;     // 标志位：是否已经找到了 CDF_min
    logic [31:0] next_cdf;
    
    assign next_cdf = cdf_acc + i_hist_rd_data;

    // 控制信号累加部分
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cdf_acc   <= '0;
            cdf_min   <= '0;
            found_min <= 1'b0;
        end 
        else if (state == S_IDLE) begin
            cdf_acc   <= '0;
            cdf_min   <= '0;
            found_min <= 1'b0;
        end 
        else if (state == S_CALC_CDF && o_hist_rd_en_d1) begin
            cdf_acc <= next_cdf;
            if (!found_min && (next_cdf > 0)) begin
                cdf_min   <= next_cdf;
                found_min <= 1'b1;
            end
        end
    end
    
    // RAM 独立写入部分
    always_ff @(posedge clk) begin   // 这里不要加 rst_n
        if (state == S_CALC_CDF && o_hist_rd_en_d1) begin
            cdf_ram[loop_cnt_d1[7:0]] <= next_cdf[23:0];
        end
    end

    // =========================================================================
    // 4. 数据通路 2：除法器 IP 实例化 (固定 Latency 适配)
    // =========================================================================
    logic [25:0] div_numer;
    logic [20:0] div_denom;
    logic [25:0] div_quotient;
    
    // 寄存除法结果
    logic [25:0] scale_factor;

    assign div_numer = 26'd16711680; 
    assign div_denom = (TOTAL_PIXELS[20:0] == cdf_min[20:0]) ? 21'd1 : (TOTAL_PIXELS[20:0] - cdf_min[20:0]);

    hist_divide u_divider (
        .clock   (clk),
        .denom   (div_denom),
        .numer   (div_numer),
        .quotient(div_quotient),
        .remain  ()
    );

    // 在等待结束的那一拍，把 IP 流水线算出的有效商锁存下来
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scale_factor <= '0;
        end else if (state == S_WAIT_DIV && timer_div == DIV_LATENCY) begin
            scale_factor <= div_quotient;
        end
    end

    // =========================================================================
    // 5. 数据通路 3：乘法计算最终 LUT 并写入映射表
    // =========================================================================
    logic [7:0]  lut_ram [0:255];
    logic [23:0] cdf_rd_data;
    
    // 乘法流水线
    logic [31:0] cur_cdf_diff;
    logic [63:0] mult_res;  
    logic [7:0]  final_lut_val; 

    // 读 CDF RAM
    always_ff @(posedge clk) begin
        if (state == S_CALC_LUT && loop_cnt < 9'd256) begin
            cdf_rd_data <= cdf_ram[loop_cnt[7:0]];
        end
    end

    // Stage 1: 计算差值并打拍 (Pipeline Reg 1)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) cur_cdf_diff <= '0;
        else if (state == S_CALC_LUT) begin
            if (cdf_rd_data > cdf_min) cur_cdf_diff <= cdf_rd_data - cdf_min;
            else                       cur_cdf_diff <= '0;
        end
    end

    // Stage 2: 乘法器打拍 (Pipeline Reg 2)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) mult_res <= '0;
        else if (state == S_CALC_LUT) begin
            mult_res <= cur_cdf_diff * scale_factor;
        end
    end

    // Stage 3: 饱和截断并写入 LUT RAM
    logic [7:0] final_lut_val;
    always_comb begin
        if ((mult_res >> 16) > 255) final_lut_val = 8'd255;
        else                        final_lut_val = mult_res[23:16];
    end

    always_ff @(posedge clk) begin
        if (state == S_CALC_LUT && loop_cnt_d3 < 9'd256) begin
            lut_ram[loop_cnt_d3[7:0]] <= final_lut_val; // 使用 loop_cnt_d3 对应流水线的 3 拍延迟 (1拍读RAM + 2拍计算)
        end
    end

    // 开放给下一级模块的读接口
    always_ff @(posedge clk) begin
        if (i_lut_rd_en) begin
            o_lut_rd_data <= lut_ram[i_lut_rd_addr];
        end
    end

    // =========================================================================
    // 6. 全局状态输出
    // =========================================================================
    logic lut_ready_reg;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lut_ready_reg <= 1'b0;
        end else if (i_frame_done) begin
            lut_ready_reg <= 1'b0; // 新帧来临，旧表失效，开始重构
        end else if (state == S_DONE) begin
            lut_ready_reg <= 1'b1; // 新表建好，允许下游读取
        end
    end

    assign o_lut_ready = lut_ready_reg;

endmodule