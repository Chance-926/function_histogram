`timescale 1ns / 1ps

module histogram_statistic #(
    parameter int IMG_WIDTH  = 1920,
    parameter int IMG_HEIGHT = 1080
)(
    input  logic        clk,          
    input  logic        rst_n,        

    // =====================================================================
    // AXI4-Stream 视频接收接口 (Sink)
    // =====================================================================
    input  logic [7:0]  s_axis_tdata,  // 灰度输入 Y
    input  logic        s_axis_tvalid, // 数据有效
    output logic        s_axis_tready, // 本模块准备好 (反压信号)
    input  logic        s_axis_tuser,  // Start of Frame (一帧的第一个像素)
    input  logic        s_axis_tlast


    // =====================================================================
    // BRAM 读取接口 (给后级 CDF 模块使用)
    // =====================================================================
    input  logic        i_ram_read_en,   
    input  logic [7:0]  i_ram_read_addr, 
    output logic [23:0] o_ram_read_data, 

    // =====================================================================
    // 触发控制
    // =====================================================================
    output logic        o_frame_done   // 触发后级模块开始计算 CDF
);

    // =========================================================================
    // 1. 状态机与 AXI-Stream 控制逻辑
    // =========================================================================
    typedef enum logic [2:0] {
        S_IDLE,         // 0: 初始态
        S_CLEAR,        // 1: RAM 清零态
        S_STAT,         // 3: 统计态 (接收 AXI 像素流)
        S_DONE,         // 4: 一帧接收完毕，发出脉冲
        S_WAIT_READ     // 5: 保护期 (等待后级 CDF 算完)
    } state_t;

    state_t state, next_state;
    
    logic [10:0] x_cnt; // 行计数器
    logic [10:0] y_cnt; // 列计数器
    logic [9:0]  st_cnt; // 清零计数器与等待计数器
    
    // AXI-Stream 握手成功标志
    logic pipe_en_in;
    assign pipe_en_in = s_axis_tvalid && s_axis_tready;

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
                if (st_cnt == 10'd255) 
                    next_state = S_STAT;
                    
            S_STAT: 
                // 当最后一行、最后一个像素握手成功时，一帧彻底结束
                if (pipe_en_in && (x_cnt == IMG_WIDTH - 1) && (y_cnt == IMG_HEIGHT - 1)) 
                    next_state = S_DONE;
                    
            S_DONE: 
                next_state = S_WAIT_READ;
                
            S_WAIT_READ: 
                // 等待 CDF 模块把 RAM 里的数据读走 (留出充裕的 buffer time)
                if (st_cnt == 10'd1000) 
                    next_state = S_CLEAR;

            default: next_state = S_IDLE;
        endcase
    end

    // s_axis_tready 反压信号生成
    // 只有在等待帧头 (S_WAIT_SOF) 和 统计像素 (S_STAT) 时，我们才接收数据。
    // 其他状态(清零、等待读取)一律拉低，死死扛住上游的数据！
    assign s_axis_tready = (state == S_STAT);
    assign o_frame_done  = (state == S_DONE);

    // =========================================================================
    // 2. 坐标与通用计数器
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st_cnt <= '0;
            x_cnt   <= '0;
            y_cnt   <= '0;
        end else begin
            // 清零与等待计数
            if (state == S_CLEAR || state == S_WAIT_READ) begin
                st_cnt <= st_cnt + 1'b1;
            end else begin
                st_cnt <= '0;
            end
            
            // X, Y 坐标计数逻辑 (完全依赖 AXI 数据流驱动)
            if (state == S_STAT && pipe_en_in) begin
                // 捕获到第一颗像素
                if (s_axis_tuser) begin
                    x_cnt <= 11'd1;
                    y_cnt <= '0;
                end else if (x_cnt == IMG_WIDTH - 1) begin
                    x_cnt <= '0;
                    y_cnt <= y_cnt + 1'b1;
                end else begin
                    x_cnt <= x_cnt + 1'b1;
                end
            end
        end
    end

    // =========================================================================
    // 3. BRAM 实例化与读取接口 
    // =========================================================================
    
    //功能：如果外界需要读取“Y分布统计”，则返回地址处的值
   (* ram_style = "block" *) logic [23:0] hist_ram [0:255];

    always_ff @(posedge clk) begin
        if (i_ram_read_en) begin
            o_ram_read_data <= hist_ram[i_ram_read_addr];
        end
    end

    // =========================================================================
    // 4. Y分布统计的读-改-写，带有防连改处理
    // =========================================================================
    logic [7:0]  tdata_d1;
    logic        valid_d1;            
    logic [23:0] ram_read_data;

    // 只有真实发生有效握手的像素，才进入统计流水线 (完美支持 AXI Stall)
    logic valid_pixel_in;
    assign valid_pixel_in = (state == S_STAT) && pipe_en_in;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tdata_d1 <= '0;
            valid_d1 <= 1'b0;
        end else begin
            tdata_d1 <= s_axis_tdata;
            valid_d1 <= valid_pixel_in;
        end
    end

    // 读 RAM 原有的统计，准备好旧统计，之后 新统计=旧统计+1
    always_ff @(posedge clk) begin
        if (valid_pixel_in) begin
            ram_read_data <= hist_ram[s_axis_tdata];
        end
    end

    // 冲突旁路逻辑
    logic [7:0]  last_write_addr;
    logic [23:0] last_write_data;  
    logic        last_write_en;    
    logic [23:0] write_data_temp;

    // 准备好新统计 （准备好write_data_temp），如果两个像素灰度一样要特殊处理
    always_comb begin
        if (last_write_en && (tdata_d1 == last_write_addr)) begin
            write_data_temp = last_write_data + 1'b1;
        end else begin
            write_data_temp = ram_read_data + 1'b1;
        end
    end

    // RAM 写操作与清零
    //第一部分：带有异步复位的控制信号 (只管状态和标志位)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            last_write_en   <= 1'b0;
            last_write_addr <= '0;
            last_write_data <= '0;
        end 
        else if (state == S_CLEAR) begin
            last_write_en <= 1'b0;
        end 
        else if (valid_d1) begin
            last_write_addr    <= tdata_d1;
            last_write_data    <= write_data_temp;
            last_write_en      <= 1'b1;
        end 
        else begin
            last_write_en <= 1'b0; 
        end
    end
    //第二部分：纯净的时钟块 (只管写 RAM) 
    //绝对不加 negedge rst_n！为了让工具放心地综合成 BRAM。
    always_ff @(posedge clk) begin
        if (state == S_CLEAR) begin
            if (st_cnt < 10'd256) begin
                hist_ram[st_cnt[7:0]] <= 24'd0; // 硬件 BRAM 的初始化清零全靠这里的遍历写 0
            end
        end 
        else if (valid_d1) begin
            hist_ram[tdata_d1] <= write_data_temp;
        end 
    end


endmodule