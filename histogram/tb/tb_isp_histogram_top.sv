`timescale 1ns / 1ps

// =========================================================================
// 模块：tb_isp_histogram_top
// 描述：标准的视频流仿真平台，读取文本，模拟 DVP 时序，写入结果
// =========================================================================
module tb_isp_histogram_top();

    // --------------------------------------------------
    // 1. 参数定义 (必须与 Python 脚本和 RTL 一致)
    // --------------------------------------------------
    localparam int IMG_WIDTH  = 512;
    localparam int IMG_HEIGHT = 512;
    localparam int TOTAL_PIX  = IMG_WIDTH * IMG_HEIGHT;

    // --------------------------------------------------
    // 2. 信号声明
    // --------------------------------------------------
    logic       clk;
    logic       rst_n;

    // DUT 输入
    logic       i_cam_vsync;
    logic       i_cam_hsync;
    logic       i_cam_de;
    logic [7:0] i_cam_r, i_cam_g, i_cam_b;

    // DUT 输出
    logic       o_disp_vsync;
    logic       o_disp_hsync;
    logic       o_disp_de;
    logic [7:0] o_disp_r, o_disp_g, o_disp_b;

    // --------------------------------------------------
    // 3. 例化顶层模块
    // --------------------------------------------------
    isp_histogram_top u_dut (
        .clk            (clk),
        .rst_n          (rst_n),
        
        .i_cam_vsync    (i_cam_vsync),
        .i_cam_hsync    (i_cam_hsync),
        .i_cam_de       (i_cam_de),
        .i_cam_r        (i_cam_r),
        .i_cam_g        (i_cam_g),
        .i_cam_b        (i_cam_b),
        
        .o_disp_vsync   (o_disp_vsync),
        .o_disp_hsync   (o_disp_hsync),
        .o_disp_de      (o_disp_de),
        .o_disp_r       (o_disp_r),
        .o_disp_g       (o_disp_g),
        .o_disp_b       (o_disp_b)
    );

    // --------------------------------------------------
    // 4. 时钟生成 (100MHz)
    // --------------------------------------------------
    initial begin
        clk = 0;
        forever #5 clk = ~clk; 
    end

    // --------------------------------------------------
    // 5. 图像内存与文件操作
    // --------------------------------------------------
    logic [23:0] img_mem [0:TOTAL_PIX-1]; // 存输入图片
    integer out_file;                     // 写输出图片的句柄

    initial begin
        // 读取 Python 生成的输入文件
        $readmemh("img_input_hex.txt", img_mem);
        // 打开准备写入的输出文件
        out_file = $fopen("img_output_hex.txt", "w");
        if (!out_file) begin
            $display("❌ 无法创建输出文件!");
            $finish;
        end
    end

    // --------------------------------------------------
    // 6. 主测试进程 (激励生成)
    // --------------------------------------------------
    initial begin
        // 初始化信号
        rst_n       = 0;
        i_cam_vsync = 0;
        i_cam_hsync = 0;
        i_cam_de    = 0;
        i_cam_r     = 0;
        i_cam_g     = 0;
        i_cam_b     = 0;

        // 复位系统
        #100;
        rst_n = 1;
        #100;

        $display("🚀 仿真开始...");

        // 核心：灌入 2 帧图像
        // 第 1 帧：用于让硬件统计直方图并计算 LUT
        $display("➡️ 开始发送第 1 帧 (建表帧)...");
        send_one_frame();
        
        // 帧间消隐区 (V-Blanking) 必须足够长！
        // 给 cdf_lut_generator 留出时间：统计(256) + 除法器(16) + 算LUT(256) ≈ 500 个周期
        #10000; 

        // 第 2 帧：硬件 LUT 已经就绪，这一帧输出的将是完美均衡化后的数据
        $display("➡️ 开始发送第 2 帧 (均衡化帧)...");
        send_one_frame();

        #5000;
        $fclose(out_file);
        $display("✅ 仿真结束！");
        $stop;
    end

    // --------------------------------------------------
    // 7. 发送一帧的 Task (模拟摄像头时序)
    // --------------------------------------------------
    task send_one_frame();
        integer x, y, pixel_idx;
        begin
            pixel_idx = 0;
            
            // 拉高场同步
            i_cam_vsync = 1;
            #100; // 模拟 VSYNC 前沿

            for (y = 0; y < IMG_HEIGHT; y = y + 1) begin
                i_cam_hsync = 1; 
                #20; // HSYNC 建立时间
                
                for (x = 0; x < IMG_WIDTH; x = x + 1) begin
                    i_cam_de = 1;
                    // 分离 RGB，注意端点对齐
                    i_cam_r  = img_mem[pixel_idx][23:16];
                    i_cam_g  = img_mem[pixel_idx][15:8];
                    i_cam_b  = img_mem[pixel_idx][7:0];
                    
                    #10; // 等待 1 个时钟周期 (100MHz = 10ns)
                    pixel_idx = pixel_idx + 1;
                end
                
                // 行结束，拉低 DE 和 HSYNC，模拟行间消隐 (H-Blanking)
                i_cam_de    = 0;
                i_cam_hsync = 0;
                #100; 
            end
            
            // 帧结束，拉低 VSYNC
            i_cam_vsync = 0;
        end
    endtask

    // --------------------------------------------------
    // 8. 监控输出流并写入文件
    // --------------------------------------------------
    // 我们只关心第 2 帧的输出数据 (此时才被均衡化)
    // 增加一个内部帧计数器来判断
    integer out_frame_cnt = 0;
    logic o_vsync_d1 = 0;

    always_ff @(posedge clk) begin
        o_vsync_d1 <= o_disp_vsync;
        // 捕捉输出 VSYNC 的下降沿，证明一帧完全输出了
        if (o_vsync_d1 && !o_disp_vsync) begin
            out_frame_cnt <= out_frame_cnt + 1;
        end
    end

    always_ff @(posedge clk) begin
        // 只有当输出 DE 为高，并且正在输出的是第 2 帧时，才写入 txt
        if (o_disp_de && out_frame_cnt == 1) begin
            $fwrite(out_file, "%02x%02x%02x\n", o_disp_r, o_disp_g, o_disp_b);
        end
    end

endmodule