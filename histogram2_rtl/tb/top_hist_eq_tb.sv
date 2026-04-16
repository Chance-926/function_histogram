`timescale 1ns / 1ps

module top_hist_eq_tb;

    // =========================================================================
    // 1. 参数与信号定义
    // =========================================================================
    localparam CLK_PERIOD = 10; 
    localparam IMG_WIDTH  = 512;
    localparam IMG_HEIGHT = 512;

    logic        clk;
    logic        rst_n;

    // 视频流输入信号 (符合硬件兼容性：VSYNC 高电平为消隐)
    logic        i_vsync;
    logic        i_hsync;
    logic        i_de;
    logic [7:0]  i_r, i_g, i_b;

    // 视频流输出信号
    logic        o_vsync;
    logic        o_de;
    logic [7:0]  o_r, o_g, o_b;

    int fid_in, fid_out;

    // =========================================================================
    // 2. DUT 实例化
    // =========================================================================
    top_hist_eq u_top_hist_eq (
        .clk     (clk),
        .rst_n   (rst_n),
        .i_vsync (i_vsync),
        .i_hsync (i_hsync),
        .i_de    (i_de),
        .i_r     (i_r),
        .i_g     (i_g),
        .i_b     (i_b),
        .o_vsync (o_vsync),
        .o_de    (o_de),
        .o_r     (o_r),
        .o_g     (o_g),
        .o_b     (o_b)
    );

    // 时钟生成
    initial begin
        clk = 0;
        forever #(CLK_PERIOD / 2) clk = ~clk;
    end

    // =========================================================================
    // 3. 主激励流程 (改进了文件操作和同步逻辑)
    // =========================================================================
    initial begin
        // 初始状态：VSYNC 为高（表示正处于消隐区/空闲态）
        rst_n = 0; i_vsync = 1; i_hsync = 0; i_de = 0;
        i_r = 0; i_g = 0; i_b = 0;

        // 文件路径建议使用绝对路径，或确保文件在仿真运行目录下
        fid_in  = $fopen("D:/AAA_Code/test_result/img_input_hex.txt", "r");
        fid_out = $fopen("D:/AAA_Code/test_result/img_output_hex.txt", "w");

        if (fid_in == 0) begin
            $display("❌ 错误: 无法打开输入文件。请检查路径。");
            $stop;
        end

        #(CLK_PERIOD * 50);
        rst_n = 1;
        #(CLK_PERIOD * 500);

        // --- 第一帧：统计数据 ---
        $display(">>> 正在发送第一帧 (VSYNC 下降沿触发统计)...");
        send_frame();

        // --- 场消隐区：VSYNC 保持高电平 ---
        // 此时模块内部状态机应处于 S_DONE -> S_WAIT_READ 阶段
        $display(">>> 进入场消隐区，等待 LUT 映射表计算...");
        #(CLK_PERIOD * 2000); 

        // --- 重新加载文件 (替代报错的 $rewind) ---
        $fclose(fid_in);
        fid_in = $fopen("D:/AAA_Code/test_result/img_input_hex.txt", "r");

        // --- 第二帧：应用均衡化 ---
        $display(">>> 正在发送第二帧 (应用均衡化结果)...");
        send_frame();
        
        #(CLK_PERIOD * 2000);
        $display(">>> 仿真任务全部完成！");
        $fclose(fid_in);
        $fclose(fid_out);
        $stop; // 使用 $stop 暂停仿真，方便观察波形
    end

    // =========================================================================
    // 4. 数据保存逻辑 (捕捉 VSYNC 下降沿作为帧计数)
    // =========================================================================
    logic o_vsync_d1;
    int frame_cnt = 0;
    always_ff @(posedge clk) o_vsync_d1 <= o_vsync;
    
    // 下降沿表示“一帧有效画面的开始”
    wire vsync_neg_edge = o_vsync_d1 && !o_vsync;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            frame_cnt <= 0;
        end else if (vsync_neg_edge) begin
            frame_cnt <= frame_cnt + 1;
            $display(">>> 检测到输出帧开始，当前 frame_cnt = %0d", frame_cnt + 1);
        end

        // 捕捉第二帧（均衡化后的结果）
        if (o_de && (frame_cnt == 2)) begin
            $fwrite(fid_out, "%02x%02x%02x\n", o_r, o_g, o_b);
        end
    end

    // =========================================================================
    // 5. send_frame Task (适配电平模式)
    // =========================================================================
    task send_frame;
        logic [23:0] hex_pixel;
        int status;
        begin
            // 1. 拉低 VSYNC，宣告场消隐结束，有效视频区开始
            i_vsync = 0;
            #(CLK_PERIOD * 20); // 模拟前消隐

            for (int y = 0; y < IMG_HEIGHT; y++) begin
                for (int x = 0; x < IMG_WIDTH; x++) begin
                    status = $fscanf(fid_in, "%h", hex_pixel);
                    
                    i_de = 1;
                    i_r  = hex_pixel[23:16];
                    i_g  = hex_pixel[15:8];
                    i_b  = hex_pixel[7:0];
                    #(CLK_PERIOD);
                end
                // 行结束
                i_de = 0; i_r = 0; i_g = 0; i_b = 0;
                #(CLK_PERIOD * 40); // 行消隐
            end

            // 2. 拉高 VSYNC，宣告画面结束，进入场消隐区
            // 此时模块内的 vsync_rising 会触发 S_STAT -> S_DONE 转换
            i_vsync = 1;
            #(CLK_PERIOD * 10);
        end
    endtask

endmodule