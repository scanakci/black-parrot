/*
 * bp_fe_pc_gen.v
 *
 * Description:
 *   The PC generation module provides the next PC for the I$ to fetch. It also
 *     send
 * pc_gen.v provides the interfaces for the pc_gen logics and also interfacing
 * other modules in the frontend. PC_gen provides the pc for the itlb and icache.
 * PC_gen also provides the BTB, BHT and RAS indexes for the backend (the queue
 * between the frontend and the backend, i.e. the frontend queue).
*/

module bp_fe_pc_gen
 import bp_common_pkg::*;
 import bp_common_rv64_pkg::*;
 import bp_fe_pkg::*;
 import bp_common_aviary_pkg::*;
 #(parameter bp_params_e bp_params_p = e_bp_inv_cfg
   `declare_bp_proc_params(bp_params_p)
   `declare_bp_fe_be_if_widths(vaddr_width_p, paddr_width_p, asid_width_p, branch_metadata_fwd_width_p)
   )
  (input                                             clk_i
   , input                                           reset_i

   // The next PC to fetch, and its metadata.
   , output [vaddr_width_p-1:0]                      next_pc_o
   , output                                          next_pc_v_o
   , input                                           next_pc_ready_i

   // Whether to redirect the next pc to fetch, used to clear the I$ pipeline
   , output                                          override_v_o

   // The fetch packet coming from the I$, containing both the fetch PC and the next fetch PC
   // Valid only, because it must be handled before the fetch goes into the queue
   , input [instr_width_p-1:0]                       fetch_instr_i
   , output [vaddr_width_p-1:0]                      fetch_pc_o
   , output [branch_metadata_fwd_width_p-1:0]        fetch_br_metadata_o
   , input                                           fetch_v_i

   // A branch resolution from the backend
   // Information is used to update the predictors and next PC. Should be consumed as
   //   soon as possible so as to not cause backpressure to the BE
   , input [vaddr_width_p-1:0]                       resolve_pc_i
   , input                                           resolve_miss_i
   , input                                           resolve_taken_i
   , input                                           resolve_nonbr_i
   , input [branch_metadata_fwd_width_p-1:0]         resolve_br_metadata_i
   , input                                           resolve_v_i
   , output                                          resolve_yumi_o
   );

  `declare_bp_fe_be_if(vaddr_width_p, paddr_width_p, asid_width_p, branch_metadata_fwd_width_p);
  `declare_bp_fe_pc_gen_stage_s(vaddr_width_p, ghist_width_p);
  `declare_bp_fe_branch_metadata_fwd_s(btb_tag_width_p, btb_idx_width_p, bht_idx_width_p, ghist_width_p);

// branch prediction wires
logic [vaddr_width_p-1:0] br_target;
logic                     ovr_ret, ovr_taken;
// btb io
logic [vaddr_width_p-1:0] btb_br_tgt_lo;
logic                     btb_br_tgt_v_lo;
logic                     btb_br_tgt_jmp_lo;

bp_fe_branch_metadata_fwd_s fetch_br_metadata;
assign fetch_br_metadata_o = fetch_br_metadata;

bp_fe_branch_metadata_fwd_s resolve_br_metadata;
assign resolve_br_metadata = resolve_br_metadata_i;

bp_fe_pc_gen_stage_s [1:0] pc_gen_stage_n, pc_gen_stage_r;

logic is_br, is_jal, is_jalr, is_call, is_ret;
logic is_br_site, is_jal_site, is_jalr_site, is_call_site, is_ret_site;
logic [btb_tag_width_p-1:0] btb_tag_site;
logic [btb_idx_width_p-1:0] btb_idx_site;
logic [bht_idx_width_p-1:0] bht_idx_site;

// Global history
//
logic [ghist_width_p-1:0] ghistory_n, ghistory_r;
wire ghistory_w_v_li = (fetch_v_i & is_br_site) | (resolve_yumi_o & resolve_miss_i);
assign ghistory_n = ghistory_w_v_li
                    ? (fetch_v_i & is_br_site)
                      ? {ghistory_r[0+:ghist_width_p-1], pc_gen_stage_r[1].taken}
                      : resolve_br_metadata.ghist
                    : ghistory_r;
bsg_dff_reset
 #(.width_p(ghist_width_p))
 ghist_reg
  (.clk_i(clk_i)
   ,.reset_i(reset_i)

   ,.data_i(ghistory_n)
   ,.data_o(ghistory_r)
   );

logic bht_pred_lo;
logic [vaddr_width_p-1:0] return_addr_n, return_addr_r;
wire btb_taken = btb_br_tgt_v_lo & (bht_pred_lo | btb_br_tgt_jmp_lo);

always_comb
  begin
    pc_gen_stage_n[0]            = '0;
    pc_gen_stage_n[0].taken      = ovr_taken | btb_taken | ovr_ret;
    pc_gen_stage_n[0].btb        = btb_br_tgt_v_lo;
    pc_gen_stage_n[0].bht        = bht_pred_lo;
    pc_gen_stage_n[0].ret        = ovr_ret;
    pc_gen_stage_n[0].ovr        = ovr_taken;
    pc_gen_stage_n[0].ghist      = ghistory_n;

    // Next PC calculation
    // load boot pc on reset command
    // if we need to redirect or load boot pc on reset
    if (resolve_yumi_o)
      begin
        pc_gen_stage_n[0].taken = resolve_taken_i;
        pc_gen_stage_n[0].btb = resolve_br_metadata.src_btb;
        pc_gen_stage_n[0].bht = '0; // Does not come from metadata
        pc_gen_stage_n[0].ret = resolve_br_metadata.src_ret;
        pc_gen_stage_n[0].ovr = '0; // Does not come from metadata
        pc_gen_stage_n[0].pc = resolve_pc_i;
      end
    else if (ovr_ret)
        pc_gen_stage_n[0].pc = return_addr_r;
    else if (ovr_taken)
        pc_gen_stage_n[0].pc = br_target;
    else if (btb_taken)
        pc_gen_stage_n[0].pc = btb_br_tgt_lo;
    else
      begin
        pc_gen_stage_n[0].pc = pc_gen_stage_r[0].pc + 4;
      end

    pc_gen_stage_n[1]    = pc_gen_stage_r[0];
  end

bsg_dff_reset
 #(.width_p($bits(bp_fe_pc_gen_stage_s)*2))
 pc_gen_stage_reg
  (.clk_i(clk_i)
   ,.reset_i(reset_i)

   ,.data_i(pc_gen_stage_n)
   ,.data_o(pc_gen_stage_r)
   );

// Branch prediction logic
always_ff @(posedge clk_i)
  begin
    if (resolve_yumi_o)
      begin
        is_br_site   <= resolve_br_metadata.is_br;
        is_jal_site  <= resolve_br_metadata.is_br;
        is_jalr_site <= resolve_br_metadata.is_jalr;
        is_call_site <= resolve_br_metadata.is_call;
        is_ret_site  <= resolve_br_metadata.is_ret;
        btb_tag_site <= resolve_br_metadata.btb_tag;
        btb_idx_site <= resolve_br_metadata.btb_idx;
        bht_idx_site <= resolve_br_metadata.bht_idx;
      end
    else if (fetch_v_i)
      begin
        is_br_site   <= is_br;
        is_jal_site  <= is_jal;
        is_jalr_site <= is_jalr;
        is_call_site <= is_call;
        is_ret_site  <= is_ret;
        btb_tag_site <= pc_gen_stage_r[1].pc[2+btb_idx_width_p+:btb_tag_width_p];
        btb_idx_site <= pc_gen_stage_r[1].pc[2+:btb_idx_width_p];
        bht_idx_site <= pc_gen_stage_r[1].pc[2+:bht_idx_width_p];
      end
  end

// Casting branch metadata forwarded from BE
wire btb_incorrect = resolve_yumi_o & ((resolve_nonbr_i & resolve_br_metadata.src_btb)
                                       | (resolve_taken_i & (~resolve_br_metadata.src_btb | resolve_miss_i)));
wire resolve_jmp = resolve_br_metadata.is_jal | resolve_br_metadata.is_jalr;
bp_fe_btb
 #(.vaddr_width_p(vaddr_width_p)
   ,.btb_tag_width_p(btb_tag_width_p)
   ,.btb_idx_width_p(btb_idx_width_p)
   )
 btb
  (.clk_i(clk_i)
   ,.reset_i(reset_i)

   ,.r_addr_i(pc_gen_stage_n[0].pc)
   ,.r_v_i(next_pc_v_o)
   ,.br_tgt_o(btb_br_tgt_lo)
   ,.br_tgt_v_o(btb_br_tgt_v_lo)
   ,.br_tgt_jmp_o(btb_br_tgt_jmp_lo)

   ,.w_v_i(btb_incorrect)
   ,.w_clr_i(resolve_nonbr_i)
   ,.w_jmp_i(resolve_jmp)
   ,.w_tag_i(resolve_br_metadata.btb_tag)
   ,.w_idx_i(resolve_br_metadata.btb_idx)
   ,.br_tgt_i(resolve_pc_i)
   );

// Local index
//
// Direct bimodal
wire [bht_idx_width_p-1:0] bht_idx_r_li = pc_gen_stage_n[0].pc[2+:bht_idx_width_p] ^ pc_gen_stage_n[0].ghist;

bp_fe_bht
 #(.vaddr_width_p(vaddr_width_p)
   ,.bht_idx_width_p(bht_idx_width_p+ghist_width_p)
   )
 bp_fe_bht
  (.clk_i(clk_i)
   ,.reset_i(reset_i)

   ,.r_v_i(next_pc_v_o)
   ,.idx_r_i({pc_gen_stage_n[0].pc[2+:bht_idx_width_p], pc_gen_stage_n[0].ghist})
   ,.predict_o(bht_pred_lo)

   ,.w_v_i(resolve_br_metadata.is_br & resolve_yumi_o)
   ,.idx_w_i({resolve_br_metadata.bht_idx, resolve_br_metadata.ghist})
   ,.correct_i(~resolve_miss_i)
   );

`declare_bp_fe_instr_scan_s(vaddr_width_p)
bp_fe_instr_scan_s scan_instr;
bp_fe_instr_scan
 #(.bp_params_p(bp_params_p))
 instr_scan
  (.instr_i(fetch_instr_i)

   ,.scan_o(scan_instr)
   );

assign is_br        = fetch_instr_i & scan_instr.branch;
assign is_jal       = fetch_instr_i & scan_instr.jal;
assign is_jalr      = fetch_instr_i & scan_instr.jalr;
assign is_call      = fetch_instr_i & scan_instr.call;
assign is_ret       = fetch_instr_i & scan_instr.ret;
wire btb_miss_ras   = ~pc_gen_stage_r[0].btb | (pc_gen_stage_r[0].pc != return_addr_r);
wire btb_miss_br    = ~pc_gen_stage_r[0].btb | (pc_gen_stage_r[0].pc != br_target);
assign ovr_ret      = btb_miss_ras & is_ret;
assign ovr_taken    = btb_miss_br & ((is_br & pc_gen_stage_r[0].bht) | is_jal);
assign br_target    = pc_gen_stage_r[1].pc + scan_instr.imm;

assign return_addr_n = pc_gen_stage_r[1].pc + vaddr_width_p'(4);
bsg_dff_reset_en
 #(.width_p(vaddr_width_p))
 ras
  (.clk_i(clk_i)
   ,.reset_i(reset_i)
   ,.en_i(is_call)

   ,.data_i(return_addr_n)
   ,.data_o(return_addr_r)
   );

assign next_pc_o = pc_gen_stage_n[0].pc;
assign next_pc_v_o = next_pc_ready_i & (~resolve_v_i | resolve_yumi_o);

assign override_v_o = ovr_taken | ovr_ret;

assign fetch_pc_o = pc_gen_stage_r[1].pc;
assign fetch_br_metadata =
  '{pred_taken: pc_gen_stage_r[1].taken | is_jalr // We can't predict target, but jalr are always taken
    ,src_btb  : pc_gen_stage_r[1].btb
    ,src_ret  : pc_gen_stage_r[1].ret
    ,src_ovr  : pc_gen_stage_r[1].ovr
    ,ghist    : pc_gen_stage_r[1].ghist
    ,is_br    : is_br_site
    ,is_jal   : is_jal_site
    ,is_jalr  : is_jalr_site
    ,is_call  : is_call_site
    ,is_ret   : is_ret_site
    ,btb_tag  : btb_tag_site
    ,btb_idx  : btb_idx_site
    ,bht_idx  : bht_idx_site
    ,default  : '0
    };

// Accept attaboys immediately, because all RAMs are 1r1w. Otherwise, accept the resolution
//   if we can actually redirect the PC
assign resolve_yumi_o = next_pc_ready_i | (resolve_v_i & ~resolve_miss_i);

endmodule
