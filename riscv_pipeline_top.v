
// 5-Stage RISC-V Core (RV32I subset) - FIXED VERSION
// Fixes vs. original:
//  1. wb_result port is now [31:0]; pc_out exported from top (no hierarchical refs)
//  2. Instruction memory pre-filled with NOPs (no X after program ends)
//  3. Register file write-through bypass (WB -> ID same cycle)
//  4. Taken branch/jump flushes BOTH IF/ID and ID/EX
//  5. JAL implemented (so "JAL 0000006F" infinite loop works)
//  6. Load-use check ignores x0
// B/J immediates now include the trailing 0 bit (no <<1 needed in the core).
// ============================================================================

module riscv_pipeline_top (
    input  wire        clk,
    input  wire        reset,
    output wire [31:0] wb_result,
    output wire [31:0] pc_out
);
    wire [31:0] instr;
    wire [31:0] mem_addr, mem_wdata, mem_rdata;
    wire        mem_write, mem_read;

    riscv_core core_inst (
        .clk(clk), .reset(reset),
        .pc_out(pc_out), .instr_in(instr),
        .mem_addr(mem_addr), .mem_wdata(mem_wdata), .mem_rdata(mem_rdata),
        .mem_write(mem_write), .mem_read(mem_read),
        .wb_result_out(wb_result)
    );

    // Instruction memory; outside its 128-byte range the core fetches NOPs,
    // so the PC can keep counting without wrapping back to the program start.
    wire [31:0] imem_out;
    instruction_memory imem (.addr(pc_out[6:2]), .instr(imem_out));
    assign instr = (pc_out[31:7] == 25'd0) ? imem_out : 32'h00000013;

    data_memory dmem (
        .clk(clk), .mem_write(mem_write), .mem_read(mem_read),
        .addr(mem_addr[6:2]), .write_data(mem_wdata), .read_data(mem_rdata)
    );
endmodule

// ----------------------------------------------------------------------------
module riscv_core (
    input  wire        clk,
    input  wire        reset,
    output wire [31:0] pc_out,
    input  wire [31:0] instr_in,
    output wire [31:0] mem_addr,
    output wire [31:0] mem_wdata,
    input  wire [31:0] mem_rdata,
    output wire        mem_write,
    output wire        mem_read,
    output wire [31:0] wb_result_out
);
    // IF/ID
    reg [31:0] IF_ID_pc, IF_ID_instr;

    // ID/EX
    reg [31:0] ID_EX_pc, ID_EX_rdata1, ID_EX_rdata2, ID_EX_imm;
    reg [4:0]  ID_EX_rs1, ID_EX_rs2, ID_EX_rd;
    reg [2:0]  ID_EX_funct3;
    reg [6:0]  ID_EX_funct7;
    reg [1:0]  ID_EX_alu_op;
    reg        ID_EX_reg_write, ID_EX_mem_to_reg, ID_EX_mem_write,
               ID_EX_mem_read, ID_EX_alu_src, ID_EX_branch, ID_EX_jump;

    // EX/MEM
    reg [31:0] EX_MEM_alu_result, EX_MEM_wdata;
    reg [4:0]  EX_MEM_rd;
    reg        EX_MEM_reg_write, EX_MEM_mem_to_reg, EX_MEM_mem_write, EX_MEM_mem_read;

    // MEM/WB
    reg [31:0] MEM_WB_rdata, MEM_WB_alu_result;
    reg [4:0]  MEM_WB_rd;
    reg        MEM_WB_reg_write, MEM_WB_mem_to_reg;

    // IF
    reg  [31:0] pc;
    wire [31:0] next_pc;
    wire        pc_stall, if_id_stall, if_id_flush, id_ex_flush;

    // ID
    wire [31:0] rf_rdata1, rf_rdata2, imm;
    wire        reg_write_ctrl, mem_to_reg_ctrl, mem_write_ctrl, mem_read_ctrl,
                alu_src_ctrl, branch_ctrl, jump_ctrl;
    wire [1:0]  alu_op_ctrl;

    // EX
    wire [1:0]  forward_a, forward_b;
    wire [31:0] alu_in_a, alu_in_b_raw, alu_in_b;
    wire [3:0]  alu_control;
    wire [31:0] alu_result, ex_result;
    wire        zero;

    // WB
    wire [31:0] wb_data = MEM_WB_mem_to_reg ? MEM_WB_rdata : MEM_WB_alu_result;
    // Raw write-back value (shows pipeline bubbles as 0)
    assign wb_result_out = wb_data;

    // ---------------- IF ----------------
    wire        take_branch   = ID_EX_branch & zero;
    wire        redirect      = take_branch | ID_EX_jump;
    wire [31:0] redirect_tgt  = ID_EX_pc + ID_EX_imm;     // imm already byte offset
    assign next_pc = redirect ? redirect_tgt : (pc + 4);

    // Halt: when the fetched instruction is "jal x0,0" (0000006F, infinite loop),
    // freeze the PC on it so it stays at one value instead of cycling.
    // A pending redirect (taken branch/jump) always has priority.
    wire halt = (instr_in == 32'h0000006F) && !redirect;

    always @(posedge clk or posedge reset) begin
        if (reset)            pc <= 32'b0;
        else if (!pc_stall && !halt) pc <= next_pc;
    end
    assign pc_out = pc;

    always @(posedge clk or posedge reset) begin
        if (reset || if_id_flush) begin
            IF_ID_pc    <= 32'b0;
            IF_ID_instr <= 32'b0;
        end else if (!if_id_stall) begin
            IF_ID_pc    <= pc;
            IF_ID_instr <= instr_in;
        end
    end

    // ---------------- ID ----------------
    register_file rf (
        .clk(clk), .we(MEM_WB_reg_write),
        .rs1(IF_ID_instr[19:15]), .rs2(IF_ID_instr[24:20]),
        .rd(MEM_WB_rd), .wdata(wb_data),
        .rdata1(rf_rdata1), .rdata2(rf_rdata2)
    );

    control_unit ctrl (
        .opcode(IF_ID_instr[6:0]),
        .reg_write(reg_write_ctrl), .mem_to_reg(mem_to_reg_ctrl),
        .mem_write(mem_write_ctrl), .mem_read(mem_read_ctrl),
        .alu_src(alu_src_ctrl), .branch(branch_ctrl), .jump(jump_ctrl),
        .alu_op(alu_op_ctrl)
    );

    imm_generator imm_gen (.instr(IF_ID_instr), .imm(imm));

    hazard_unit hu (
        .id_ex_mem_read(ID_EX_mem_read), .id_ex_rd(ID_EX_rd),
        .if_id_rs1(IF_ID_instr[19:15]), .if_id_rs2(IF_ID_instr[24:20]),
        .redirect(redirect),
        .pc_stall(pc_stall), .if_id_stall(if_id_stall),
        .if_id_flush(if_id_flush), .id_ex_flush(id_ex_flush)
    );

    always @(posedge clk or posedge reset) begin
        if (reset || id_ex_flush) begin   // bubble on load-use stall OR taken branch/jump
            ID_EX_pc <= 32'b0; ID_EX_rdata1 <= 32'b0; ID_EX_rdata2 <= 32'b0;
            ID_EX_imm <= 32'b0; ID_EX_rs1 <= 5'b0; ID_EX_rs2 <= 5'b0; ID_EX_rd <= 5'b0;
            ID_EX_funct3 <= 3'b0; ID_EX_funct7 <= 7'b0; ID_EX_alu_op <= 2'b0;
            ID_EX_reg_write <= 1'b0; ID_EX_mem_to_reg <= 1'b0; ID_EX_mem_write <= 1'b0;
            ID_EX_mem_read <= 1'b0; ID_EX_alu_src <= 1'b0; ID_EX_branch <= 1'b0;
            ID_EX_jump <= 1'b0;
        end else begin
            ID_EX_pc <= IF_ID_pc;
            ID_EX_rdata1 <= rf_rdata1;
            ID_EX_rdata2 <= rf_rdata2;
            ID_EX_imm <= imm;
            ID_EX_rs1 <= IF_ID_instr[19:15];
            ID_EX_rs2 <= IF_ID_instr[24:20];
            ID_EX_rd  <= IF_ID_instr[11:7];
            ID_EX_funct3 <= IF_ID_instr[14:12];
            ID_EX_funct7 <= IF_ID_instr[31:25];
            ID_EX_alu_op <= alu_op_ctrl;
            ID_EX_reg_write <= reg_write_ctrl;
            ID_EX_mem_to_reg <= mem_to_reg_ctrl;
            ID_EX_mem_write <= mem_write_ctrl;
            ID_EX_mem_read <= mem_read_ctrl;
            ID_EX_alu_src <= alu_src_ctrl;
            ID_EX_branch <= branch_ctrl;
            ID_EX_jump <= jump_ctrl;
        end
    end

    // ---------------- EX ----------------
    forwarding_unit fu (
        .id_ex_rs1(ID_EX_rs1), .id_ex_rs2(ID_EX_rs2),
        .ex_mem_rd(EX_MEM_rd), .ex_mem_reg_write(EX_MEM_reg_write),
        .mem_wb_rd(MEM_WB_rd), .mem_wb_reg_write(MEM_WB_reg_write),
        .forward_a(forward_a), .forward_b(forward_b)
    );

    assign alu_in_a = (forward_a == 2'b10) ? EX_MEM_alu_result :
                      (forward_a == 2'b01) ? wb_data : ID_EX_rdata1;
    assign alu_in_b_raw = (forward_b == 2'b10) ? EX_MEM_alu_result :
                          (forward_b == 2'b01) ? wb_data : ID_EX_rdata2;
    assign alu_in_b = ID_EX_alu_src ? ID_EX_imm : alu_in_b_raw;

    alu_control_unit alu_ctrl (
        .alu_op(ID_EX_alu_op), .funct3(ID_EX_funct3), .funct7(ID_EX_funct7),
        .alu_control(alu_control)
    );

    alu execution_unit (
        .a(alu_in_a), .b(alu_in_b), .alu_ctrl(alu_control),
        .result(alu_result), .zero(zero)
    );

    // JAL writes PC+4 to rd
    assign ex_result = ID_EX_jump ? (ID_EX_pc + 32'd4) : alu_result;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            EX_MEM_alu_result <= 32'b0; EX_MEM_wdata <= 32'b0; EX_MEM_rd <= 5'b0;
            EX_MEM_reg_write <= 1'b0; EX_MEM_mem_to_reg <= 1'b0;
            EX_MEM_mem_write <= 1'b0; EX_MEM_mem_read <= 1'b0;
        end else begin
            EX_MEM_alu_result <= ex_result;
            EX_MEM_wdata      <= alu_in_b_raw;
            EX_MEM_rd         <= ID_EX_rd;
            EX_MEM_reg_write  <= ID_EX_reg_write;
            EX_MEM_mem_to_reg <= ID_EX_mem_to_reg;
            EX_MEM_mem_write  <= ID_EX_mem_write;
            EX_MEM_mem_read   <= ID_EX_mem_read;
        end
    end

    // ---------------- MEM ----------------
    assign mem_addr  = EX_MEM_alu_result;
    assign mem_wdata = EX_MEM_wdata;
    assign mem_write = EX_MEM_mem_write;
    assign mem_read  = EX_MEM_mem_read;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            MEM_WB_rdata <= 32'b0; MEM_WB_alu_result <= 32'b0; MEM_WB_rd <= 5'b0;
            MEM_WB_reg_write <= 1'b0; MEM_WB_mem_to_reg <= 1'b0;
        end else begin
            MEM_WB_rdata      <= mem_rdata;
            MEM_WB_alu_result <= EX_MEM_alu_result;
            MEM_WB_rd         <= EX_MEM_rd;
            MEM_WB_reg_write  <= EX_MEM_reg_write;
            MEM_WB_mem_to_reg <= EX_MEM_mem_to_reg;
        end
    end
endmodule

// ----------------------------------------------------------------------------
// Sub-modules
// ----------------------------------------------------------------------------
module register_file (
    input  wire        clk,
    input  wire        we,
    input  wire [4:0]  rs1, rs2, rd,
    input  wire [31:0] wdata,
    output wire [31:0] rdata1, rdata2
);
    reg [31:0] registers [31:0];
    integer i;
    initial for (i = 0; i < 32; i = i + 1) registers[i] = 32'b0;

    always @(posedge clk)
        if (we && (rd != 5'b0)) registers[rd] <= wdata;

    // Write-through bypass: a value being written this cycle is visible to reads
    assign rdata1 = (rs1 == 5'b0)            ? 32'b0 :
                    (we && rd == rs1)        ? wdata : registers[rs1];
    assign rdata2 = (rs2 == 5'b0)            ? 32'b0 :
                    (we && rd == rs2)        ? wdata : registers[rs2];
endmodule

module control_unit (
    input  wire [6:0] opcode,
    output reg reg_write, mem_to_reg, mem_write, mem_read, alu_src, branch, jump,
    output reg [1:0] alu_op
);
    always @(*) begin
        reg_write = 0; mem_to_reg = 0; mem_write = 0; mem_read = 0;
        alu_src = 0; branch = 0; jump = 0; alu_op = 2'b00;
        case (opcode)
            7'b0110011: begin reg_write = 1; alu_op = 2'b10; end                       // R-type
            7'b0010011: begin reg_write = 1; alu_src = 1; end                          // I-type ALU
            7'b0000011: begin reg_write = 1; mem_to_reg = 1; mem_read = 1; alu_src = 1; end // LW
            7'b0100011: begin mem_write = 1; alu_src = 1; end                          // SW
            7'b1100011: begin branch = 1; alu_op = 2'b01; end                          // BEQ
            7'b1101111: begin reg_write = 1; jump = 1; end                             // JAL
            default: ;
        endcase
    end
endmodule

module imm_generator (
    input  wire [31:0] instr,
    output reg  [31:0] imm
);
    always @(*) begin
        case (instr[6:0])
            7'b0010011, 7'b0000011:  // I-type
                imm = {{20{instr[31]}}, instr[31:20]};
            7'b0100011:              // S-type
                imm = {{20{instr[31]}}, instr[31:25], instr[11:7]};
            7'b1100011:              // B-type (byte offset)
                imm = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};
            7'b1101111:              // J-type (byte offset)
                imm = {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};
            default: imm = 32'b0;
        endcase
    end
endmodule

module alu_control_unit (
    input  wire [1:0] alu_op,
    input  wire [2:0] funct3,
    input  wire [6:0] funct7,
    output reg  [3:0] alu_control
);
    always @(*) begin
        case (alu_op)
            2'b00: alu_control = 4'b0010;          // ADD
            2'b01: alu_control = 4'b0110;          // SUB (BEQ)
            2'b10: case (funct3)
                3'b000:  alu_control = funct7[5] ? 4'b0110 : 4'b0010;
                3'b111:  alu_control = 4'b0000;    // AND
                3'b110:  alu_control = 4'b0001;    // OR
                default: alu_control = 4'b0010;
            endcase
            default: alu_control = 4'b0010;
        endcase
    end
endmodule

module alu (
    input  wire [31:0] a, b,
    input  wire [3:0]  alu_ctrl,
    output reg  [31:0] result,
    output wire        zero
);
    always @(*) begin
        case (alu_ctrl)
            4'b0000: result = a & b;
            4'b0001: result = a | b;
            4'b0010: result = a + b;
            4'b0110: result = a - b;
            default: result = 32'b0;
        endcase
    end
    assign zero = (result == 32'b0);
endmodule

module hazard_unit (
    input  wire       id_ex_mem_read,
    input  wire [4:0] id_ex_rd,
    input  wire [4:0] if_id_rs1, if_id_rs2,
    input  wire       redirect,          // taken branch or jump resolved in EX
    output reg        pc_stall, if_id_stall, if_id_flush, id_ex_flush
);
    wire load_use = id_ex_mem_read && (id_ex_rd != 5'b0) &&
                    ((id_ex_rd == if_id_rs1) || (id_ex_rd == if_id_rs2));
    always @(*) begin
        pc_stall    = load_use;
        if_id_stall = load_use;
        if_id_flush = redirect;
        id_ex_flush = load_use | redirect;   // bubble into EX
    end
endmodule

module forwarding_unit (
    input  wire [4:0] id_ex_rs1, id_ex_rs2,
    input  wire [4:0] ex_mem_rd,
    input  wire       ex_mem_reg_write,
    input  wire [4:0] mem_wb_rd,
    input  wire       mem_wb_reg_write,
    output reg  [1:0] forward_a, forward_b
);
    always @(*) begin
        forward_a = 2'b00;
        forward_b = 2'b00;
        if (ex_mem_reg_write && ex_mem_rd != 0 && ex_mem_rd == id_ex_rs1)      forward_a = 2'b10;
        else if (mem_wb_reg_write && mem_wb_rd != 0 && mem_wb_rd == id_ex_rs1) forward_a = 2'b01;
        if (ex_mem_reg_write && ex_mem_rd != 0 && ex_mem_rd == id_ex_rs2)      forward_b = 2'b10;
        else if (mem_wb_reg_write && mem_wb_rd != 0 && mem_wb_rd == id_ex_rs2) forward_b = 2'b01;
    end
endmodule

module instruction_memory (
    input  wire [4:0]  addr,
    output wire [31:0] instr
);
    reg [31:0] mem [0:31];
    integer i;

    initial begin
        for (i = 0; i < 32; i = i + 1)
            mem[i] = 32'h00000013;      // NOP fill

        mem[0] = 32'h00500093;          // addi x1, x0, 5
        mem[1] = 32'h00a00113;          // addi x2, x0, 10
        mem[2] = 32'h002081b3;          // add  x3, x1, x2
        mem[3] = 32'h00302023;          // sw   x3, 0(x0)
        mem[4] = 32'h00002203;          // lw   x4, 0(x0)
        mem[5] = 32'h001202b3;          // add  x5, x4, x1
    end

    assign instr = mem[addr];
endmodule

module data_memory (
    input  wire        clk, mem_write, mem_read,
    input  wire [4:0]  addr,
    input  wire [31:0] write_data,
    output wire [31:0] read_data
);
    reg [31:0] mem [31:0];
    integer i;
    initial for (i = 0; i < 32; i = i + 1) mem[i] = 32'b0;

    always @(posedge clk) if (mem_write) mem[addr] <= write_data;
    assign read_data = mem_read ? mem[addr] : 32'b0;
endmodule