`timescale 1ns / 1ps

//1.
//确认 STM32 的配置代码，确保 VSYNC 被配置为 VSYNC 为高电平代表消隐区。
//这样当你的状态机捕捉到 VSYNC 上升沿时，意味着上一帧彻底结束，消隐区刚开始。
//你有充足的时间（通常几十万个时钟周期）去建表。

//2.有清零前摇

module histogram_statistic (
    input  logic        clk,          
    input  logic        rst_n,        

    input  logic        i_vsync,   
    input  logic        i_hsync,      
    input  logic        i_de,         
    input  logic [7:0]  i_y,          

    input  logic        i_ram_read_en,   
    input  logic [7:0]  i_ram_read_addr, 
    output logic [23:0] o_ram_read_data, 

    output logic        o_frame_done     
);

    // =========================================================================
    // 1. 状态机定义：严谨处理 DVP 脉冲时序
    // =========================================================================
    typedef enum logic [2:0] {
        S_IDLE,         // 0: 初始态
        S_CLEAR,        // 1: RAM 清零态 (开机或帧间共用)
        S_WAIT_VSYNC,   // 2: 等待消隐区结束 (等待 VSYNC 下降沿)
        S_STAT,         // 3: 统计态 (接收 i_de 数据)
        S_DONE,         // 4: 帧结束交接 (等待 VSYNC 上升沿触发)
        S_WAIT_READ     // 5: 保护期 (等待后级算完 LUT)
    } state_t;

    state_t state, next_state;
    logic [9:0] cnt; // 共用计数器

    // 存一拍 VSYNC 上升沿
    logic vsync_d1;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vsync_d1 <= '0;
        end else begin
            vsync_d1 <= i_vsync;
        end
    end

    logic vsync_falling;
    logic vsync_rising;
    assign vsync_falling = vsync_d1 & ~i_vsync;// 下降沿：高变低 -> 消隐结束，准备接收有效像素
    assign vsync_rising  = ~vsync_d1 & i_vsync;// 上升沿：低变高 -> 像素发完，进入消隐区，可以开始算表了


    // 状态机跳转逻辑
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= S_IDLE;
        else        state <= next_state;
    end

    always_comb begin
        next_state = state;
        case (state)
            S_IDLE: 
                next_state = S_CLEAR;
            
            S_CLEAR: 
                if (cnt == 10'd255) next_state = S_WAIT_VSYNC; 

            S_WAIT_VSYNC: 
                if (vsync_falling) next_state = S_STAT;

            S_STAT: 
                // 由于 VSYNC 信号的设定，只有看到下一个 VSYNC 上升沿，才代表当前帧彻底传完，进入交接。
                if (vsync_rising) next_state = S_DONE;

            S_DONE: 
                next_state = S_WAIT_READ;

            S_WAIT_READ: 
                if (cnt == 10'd1000) next_state = S_CLEAR; // 读完去清零，准备下一帧

            default: next_state = S_IDLE;
        endcase
    end


    assign o_frame_done = (state == S_DONE);

    // 计数器逻辑
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) cnt <= '0;
        else if (state == S_CLEAR || state == S_WAIT_READ) begin
            cnt <= cnt + 1'b1;
        end else begin
            cnt <= '0;
        end
    end

    // =========================================================================
    // 2. RAM 实例化与读取接口
    // =========================================================================
  
    //功能：如果外界需要读取ram，则返回地址处的值
    logic [23:0] hist_ram [0:255]; 

    always_ff @(posedge clk) begin
        if (i_ram_read_en) begin
            o_ram_read_data <= hist_ram[i_ram_read_addr];
        end
    end

    // =========================================================================
    // 3. 统计写入与防冲突逻辑
    // =========================================================================
    logic [7:0]  y_d1;             
    logic        de_d1;            
    logic [23:0] ram_read_data;    

    // 延迟一拍
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            y_d1  <= '0;
            de_d1 <= 1'b0;
        end else begin
            y_d1  <= i_y;
            de_d1 <= (state == S_STAT && i_de);
        end
    end


    logic [7:0]  last_write_addr;  
    logic [23:0] last_write_data;  
    logic        last_write_en;    
    logic [23:0] write_data_temp;    
        
    // 读 RAM 原有的统计，准备好旧统计，之后 新统计=旧统计+1
    always_ff @(posedge clk) begin
        if (state == S_STAT && i_de) begin
            ram_read_data <= hist_ram[i_y]; 
        end
    end

    // 准备好新统计 （准备好write_data_temp），如果两个像素灰度一样要特殊处理
    always_comb begin
        if (last_write_en && (y_d1 == last_write_addr)) begin
            write_data_temp = last_write_data + 1'b1; 
        end else begin
            write_data_temp = ram_read_data + 1'b1;   
        end
    end

    // 时序逻辑：纯粹的寄存器打拍和 RAM 写入 
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            last_write_en   <= 1'b0;
            last_write_addr <= '0;
            last_write_data <= '0;
        end 

        else if (state == S_CLEAR) begin
            if (cnt < 10'd256) begin
                hist_ram[cnt[7:0]] <= 24'd0; 
            end
            last_write_en <= 1'b0;
        end 

        else if (de_d1) begin
            hist_ram[y_d1] <= write_data_temp;
            last_write_addr <= y_d1;
            last_write_data <= write_data_temp;
            last_write_en   <= 1'b1;
        end 

        else begin
            last_write_en <= 1'b0;
        end
    end

endmodule


