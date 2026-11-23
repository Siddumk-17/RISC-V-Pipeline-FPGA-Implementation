`timescale 1ns / 1ps

module tb_riscv_pipeline_top;

    reg         clk;
    reg         reset;
    wire [31:0] wb_result;
    wire [31:0] pc_out;

    integer cycles;

    riscv_pipeline_top uut (
        .clk       (clk),
        .reset     (reset),
        .wb_result (wb_result),
        .pc_out    (pc_out)
    );

    // 100 MHz clock
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // Cycle counter (counts clocks after reset is released)
    initial cycles = 0;
    always @(posedge clk) if (!reset) cycles <= cycles + 1;

    initial begin
        reset = 1'b1;
        #20 reset = 1'b0;

        // End the run on a PC count: stop when PC reaches 76 (about 215 ns)
        wait (pc_out == 32'd76);
        #1;

        $display("--------------------------------------------------");
        $display("Finished at PC = %0d after %0d clock cycles", pc_out, cycles);
        $display("Final wb_result = %0d", wb_result);
        $display("x1=%0d x2=%0d x3=%0d x4=%0d x5=%0d mem[0]=%0d",
                 uut.core_inst.rf.registers[1], uut.core_inst.rf.registers[2],
                 uut.core_inst.rf.registers[3], uut.core_inst.rf.registers[4],
                 uut.core_inst.rf.registers[5],
                 uut.dmem.mem[0]);

        if (uut.core_inst.rf.registers[1] == 5  &&
            uut.core_inst.rf.registers[2] == 10 &&
            uut.core_inst.rf.registers[3] == 15 &&
            uut.core_inst.rf.registers[4] == 15 &&
            uut.core_inst.rf.registers[5] == 20 &&
            uut.dmem.mem[0]               == 15 &&
            wb_result                     == 0)
            $display("RESULT: PASS");
        else
            $display("RESULT: FAIL");
        $display("--------------------------------------------------");

        $finish;
    end

    initial begin
        $monitor("t=%0t | PC=%0d | wb_result=%0d", $time, pc_out, wb_result);
    end

endmodule
