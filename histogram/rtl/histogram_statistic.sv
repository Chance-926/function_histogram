`timescale 1ns / 1ps

module histogram_statistic (
    input  logic        clk,          // 系统时钟（心脏的跳动，每个上升沿代表一拍）
    input  logic        rst_n,        // 复位信号（低电平有效，也就是为 0 时系统重置）

    // 从上一级 (RGB转YCbCr) 传来的图像数据流
    input  logic        i_vsync,      // 场同步信号：高电平代表正在传一帧图像，拉低代表这一帧结束了
    input  logic        i_hsync,      // 行同步信号：代表正在传一行
    input  logic        i_de,         // 数据有效信号 (Data Enable)：为 1 时，代表 i_y 里的数据是真实有效的像素
    input  logic [7:0]  i_y,          // 亮度数据 (0~255)

    // 留给下一级 (算 CDF 的模块) 读取数据的接口
    input  logic        i_ram_read_en,   // 下一级说：“我要读数据了”
    input  logic [7:0]  i_ram_read_addr, // 下一级说：“我要读哪个灰度值的统计结果？”
    output logic [23:0] o_ram_read_data, // 给下一级吐出对应的统计数量

    // 状态输出
    output logic        o_frame_done     // 给下一级发信号：“ 这一帧清零和统计都干完了，可以开始算 CDF ”
);

    // =========================================================================
    // 1. 状态机定义与控制逻辑
    // =========================================================================
    // 定义三个状态（枚举类型），就像红绿灯的三种颜色
    typedef enum logic [1:0] {
        S_IDLE,    // 黑屏时间的尾声，BRAM 已经清空了，但下一帧图像的第一个像素还没到，系统处于 S_IDLE，进入“静默等待”模式，什么也不做，节省功耗。
        S_CLEAR,   // 清零状态 (把RAM里上一帧的旧数据擦除)
        S_STAT     // 统计状态 (接收新像素并计数)
    } state_t;

    state_t state, next_state;   // state 是当前状态，next_state 是即将进入的状态
    logic [8:0] clear_cnt;       // 一个计数器，用来生成 0 到 255 的地址去清零 RAM

    // --- 捕捉 VSYNC 的下降沿 ---
    // 为什么要捕捉下降沿？因为 VSYNC 从 1 变成 0 的那一瞬间，说明一帧图像刚刚传完，
    // 进入了珍贵的“消隐区（不传数据的空白时间）”，我们要在此时抓紧时间清零 RAM。
    logic vsync_d1; // 用来记住上一拍的 vsync 是啥
    always_ff @(posedge clk) vsync_d1 <= i_vsync;
    // 如果上一拍是 1，这一拍是 0，说明下降沿到了！
    logic vsync_falling = vsync_d1 & ~i_vsync; 

    // --- 状态机的第一段：状态寄存器（记忆当前状态） ---
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= S_IDLE;     // 如果复位，回到待机
        else        state <= next_state; // 否则，跟着下一个状态走
    end

    // --- 状态机的第二段：状态转移逻辑（决定怎么跳转） ---
    // always_comb 表示这是纯组合逻辑，没有时钟触发，条件满足立刻变化
    always_comb begin
        next_state = state; // 默认情况下，保持当前状态不变
        case (state)
            S_IDLE:  
                if (vsync_falling) next_state = S_CLEAR; // 一帧结束了，准备清零
            S_CLEAR: 
                if (clear_cnt == 9'd256) next_state = S_STAT; // 数了 256 下，清零干完了，准备统计
            S_STAT:  
                if (vsync_falling) next_state = S_CLEAR; // 这一帧又统计完了，循环，再去清零
            default: next_state = S_IDLE;
        endcase
    end

    // --- 清零用的计数器 ---
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            clear_cnt <= '0;
        end else if (state == S_CLEAR) begin
            clear_cnt <= clear_cnt + 1'b1; // 在清零状态下，每过一个时钟加 1 (0,1,2...255)
        end else begin
            clear_cnt <= '0; // 不在清零状态时，乖乖清零等着
        end
    end

    // 当状态是 S_CLEAR 且正好数到 256 的那一拍，拉高 o_frame_done
    assign o_frame_done = (state == S_CLEAR && clear_cnt == 9'd256);


    // =========================================================================
    // 2. BRAM (块RAM) 实例化
    // 这相当于 FPGA 内部的一个大数组，有 256 个抽屉，每个抽屉能存 24 bit 的数字
    // =========================================================================
    logic [23:0] hist_ram [0:255]; // 256深度，24位宽

    // RAM 的 B 端口：专门给下一级读取用的
    always_ff @(posedge clk) begin
        if (i_ram_read_en) begin
            // 只要读取使能为高，就把对应地址抽屉里的数字拿出来
            o_ram_read_data <= hist_ram[i_ram_read_addr];//某个灰度值的像素分布
        end
    end


    // =========================================================================
    // 3. 核心统计逻辑 (读-改-写 与 防冲突)
    // =========================================================================
    logic [7:0]  y_d1;             // 把输入的灰度值延迟一拍
    logic        de_d1;            // 把有效信号延迟一拍
    logic [23:0] ram_read_data;    // 从 RAM 里读出来的值

    // --- 步骤 1：读出当前灰度值以前出现的次数 ---
    always_ff @(posedge clk) begin
        if (state == S_STAT && i_de) begin
            // 把像素值 i_y 当作抽屉的地址，去 RAM 里读现在的数量
            // 注意：硬件读 RAM 是需要消耗 1 个时钟周期的！
            ram_read_data <= hist_ram[i_y]; 
        end
    end

    // 因为读 RAM 消耗了 1 个周期，此时输入的数据 i_y 已经跑远了。
    // 为了防止一会儿写回 BRAM 时找不到原来的灰度值（地址），
    // 我们必须用寄存器把 i_y 和 i_de 挽留（延迟）一个时钟周期，强行和读出的数据对齐！
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            y_d1  <= '0;
            de_d1 <= 1'b0;
        end else begin
            y_d1  <= i_y;
            de_d1 <= (state == S_STAT && i_de);
        end
    end


    // --- 步骤 2：加 1 并写回 (带防冲突机制) ---
    logic [7:0]  last_write_addr;  // 记录上一次是往哪个抽屉写的
    logic [23:0] last_write_data;  // 记录上一次往抽屉里写了什么数字
    logic        last_write_en;    // 记录上一次是不是真的写了
    logic [23:0] write_data_temp;  // 准备要写回的新数字

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            last_write_en   <= 1'b0;
            last_write_addr <= '0;
            last_write_data <= '0;
        end 
        
        else if (state == S_CLEAR) begin
            // 如果处于清零状态，我们就用 clear_cnt 当地址，往所有抽屉里塞 0
            if (clear_cnt < 9'd256) begin
                hist_ram[clear_cnt[7:0]] <= 24'd0; 
            end
            last_write_en <= 1'b0;
        end 
        
        else if (de_d1) begin
            // 此时，我们在【统计状态】，并且从 RAM 里读出旧数据了

            // 【防冲突机制】：如果连续来了两个亮度一样的像素（比如都是 100）
            // 我们当前要处理的像素(y_d1)，如果发现和上一拍刚刚处理完的像素(last_write_addr)是一样的亮度！
            if (last_write_en && (y_d1 == last_write_addr)) begin
                // 千万别用从 RAM 里读出的旧数据！因为上一拍的新数据还没真正存进 RAM 里！
                // 直接用上一次加完的临时结果再加 1
                write_data_temp = last_write_data + 1'b1; 
            end else begin
                // 如果前后两个像素亮度不一样，那就安全了，老老实实用 RAM 里读出的旧数据加 1
                write_data_temp = ram_read_data + 1'b1;   
            end

            // 算出了最终的新数量，写回 RAM 对应的抽屉里
            hist_ram[y_d1] <= write_data_temp;

            // 关键动作：把这次写的地址和数据记下来，留给下一个像素做“防冲突”比对用
            last_write_addr <= y_d1;
            last_write_data <= write_data_temp;

            last_write_en <= 1'b1;
        end 

        else last_write_en <= 1'b0;
    end

endmodule