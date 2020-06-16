
module bp_nonsynth_dcache_tracer
 import bp_common_pkg::*;
 import bp_common_aviary_pkg::*;
 import bp_be_pkg::*;
 import bp_common_rv64_pkg::*;
 #( parameter bp_params_e bp_params_p = e_bp_inv_cfg
   `declare_bp_proc_params(bp_params_p)

  , parameter assoc_p = 8
  , parameter sets_p = 64
  , parameter block_width_p = 512
  , parameter trace_file_p = "dcache"

   // Calculated parameters
   , localparam lg_assoc_lp = `BSG_SAFE_CLOG2(assoc_p)
   , localparam lg_sets_lp = `BSG_SAFE_CLOG2(sets_p)
   , localparam block_size_in_bytes_lp = (block_width_p/8)
   , localparam block_offset_width_lp = `BSG_SAFE_CLOG2(block_size_in_bytes_lp)
   , localparam ptag_width_lp=(paddr_width_p-lg_sets_lp-block_offset_width_lp)

   , localparam mhartid_width_lp = `BSG_SAFE_CLOG2(num_core_p)

   `declare_bp_cache_service_if_widths(paddr_width_p, ptag_width_p, sets_p, assoc_p, dword_width_p, block_width_p, cache)

   )
  (  input                                                 clk_i
   , input                                                 reset_i

   , input                                                 freeze_i
   , input [mhartid_width_lp-1:0]                          mhartid_i


   // Cache requests
   //, input                                                 v_i
   //, input                                                 ready_o

   // Tag Verify stage
   , input                                                 v_tv_r
   , input                                                 miss_tv
   , input [paddr_width_p-1:0]                             addr_tv_r
   , input [dword_width_p-1:0]                             data_tv_r

   , input                                                 fencei_op_tv_r

   , input                                                 load_op_tv_r
   , input                                                 load_hit_tv
   , input                                                 load_miss_tv
   , input                                                 store_op_tv_r
   , input                                                 store_hit_tv
   , input                                                 store_miss_tv

   , input                                                 uncached_tv_r

   , input                                                 lr_op_tv_r
   , input                                                 lr_miss_tv
   , input                                                 lr_hit_tv
   , input                                                 sc_op_tv_r
   , input                                                 sc_success
   , input                                                 sc_fail

   // LCE Request - Cache Miss
   , input                                                 cache_req_v_o
   , input [cache_req_width_lp-1:0]                        cache_req_o
   , input [cache_req_metadata_width_lp-1:0]               cache_req_metadata_o
   , input                                                 cache_req_metadata_v_o
   , input                                                 cache_req_complete_i

   // Cache response
   , input                                                 v_o
   , input [dword_width_p-1:0]                             data_o

   // Fill Packets
   , input                                                 data_mem_pkt_v_i
   , input [cache_data_mem_pkt_width_lp-1:0]               data_mem_pkt_i
   , input                                                 data_mem_pkt_yumi_o

   , input                                                 tag_mem_pkt_v_i
   , input [cache_tag_mem_pkt_width_lp-1:0]                tag_mem_pkt_i
   , input                                                 tag_mem_pkt_yumi_o

   , input                                                 stat_mem_pkt_v_i
   , input [cache_stat_mem_pkt_width_lp-1:0]               stat_mem_pkt_i
   , input                                                 stat_mem_pkt_yumi_o

   , input                                                 wbuf_overflow
   , input                                                 wt_req
   );

  `declare_bp_cache_service_if(paddr_width_p, ptag_width_p, sets_p, assoc_p, dword_width_p, block_width_p, cache);

  // Input Casting
  bp_cache_req_s cache_req_cast_o;
  bp_cache_req_metadata_s cache_req_metadata_cast_o;
  assign cache_req_cast_o = cache_req_o;
  assign cache_req_metadata_cast_o = cache_req_metadata_o;

  bp_cache_data_mem_pkt_s data_mem_pkt_cast_i;
  bp_cache_tag_mem_pkt_s tag_mem_pkt_cast_i;
  bp_cache_stat_mem_pkt_s stat_mem_pkt_cast_i;
  assign data_mem_pkt_cast_i = data_mem_pkt_i;
  assign tag_mem_pkt_cast_i = tag_mem_pkt_i;
  assign stat_mem_pkt_cast_i = stat_mem_pkt_i;

  integer file;
  string file_name;

  wire delay_li = reset_i | freeze_i;
  always_ff @(negedge delay_li)
   begin
     file_name = $sformatf("%s_%x.trace", trace_file_p, mhartid_i);
     file      = $fopen(file_name, "w");
     $fwrite(file, "Coherent L1: %x\n", l1_coherent_p);
   end

  string op, data_op, tag_op, stat_op;

  always_comb begin
    if (lr_miss_tv & cache_req_v_o)
      op = "[lr]";
    else if(sc_op_tv_r)
      op = "[sc]";
    else if (cache_req_v_o & cache_req_cast_o.msg_type == e_miss_store)
      op = "[store]";
    else if (cache_req_v_o & cache_req_cast_o.msg_type == e_miss_load)
      op = "[load]";
    else if (cache_req_v_o & cache_req_cast_o.msg_type == e_uc_load)
      op = "[uncached load]";
    else if (cache_req_v_o & cache_req_cast_o.msg_type == e_wt_store)
      op = "[writethrough store]";
    else if (cache_req_v_o & cache_req_cast_o.msg_type == e_uc_store)
      op = "[uncached store]";
    else if (cache_req_v_o & cache_req_cast_o.msg_type == e_cache_flush)
      op = "[fencei req]";
    else if (cache_req_v_o & cache_req_cast_o.msg_type == e_cache_clear)
      op = "[fencei req]";
    else
      op = "[null]";
  end

  always_comb begin
    if (data_mem_pkt_cast_i.opcode == e_cache_data_mem_read)
      data_op = "[read]";
    else if (data_mem_pkt_cast_i.opcode == e_cache_data_mem_uncached)
      data_op = "[uncached]";
    else if (data_mem_pkt_cast_i.opcode == e_cache_data_mem_write)
      data_op = "[write]";
    else
      data_op = "[null]";

    if (tag_mem_pkt_cast_i.opcode == e_cache_tag_mem_set_clear)
      tag_op = "[set clear]";
    else if (tag_mem_pkt_cast_i.opcode == e_cache_tag_mem_set_tag)
      tag_op = "[set tag]";
    else if (tag_mem_pkt_cast_i.opcode == e_cache_tag_mem_invalidate)
      tag_op = "[invalidate]";
    else if (tag_mem_pkt_cast_i.opcode == e_cache_tag_mem_read)
      tag_op = "[read]";
    else
      tag_op = "[null]";

    if (stat_mem_pkt_cast_i.opcode == e_cache_stat_mem_read)
      stat_op = "[read]";
    else if (stat_mem_pkt_cast_i.opcode == e_cache_stat_mem_set_clear)
      stat_op = "[set clear]";
    else if (stat_mem_pkt_cast_i.opcode == e_cache_stat_mem_clear_dirty)
      stat_op = "[clear dirty]";
    else
      stat_op = "[null]";
  end

  always_ff @(posedge clk_i) begin

      if (wbuf_overflow) begin
        $fwrite(file, "[%t] Write buffer overflow!\n", $time);
      end

      if (wt_req)
        $fwrite(file, "[%t] Writethrough incoming\n", $time);

      // Cache Hits
      if (v_o) begin
        if (v_tv_r & load_op_tv_r & load_hit_tv & ~uncached_tv_r & ~miss_tv & ~fencei_op_tv_r) begin
          $fwrite(file, "[%t] Load hit: addr: %x index: %x data: %x\n", $time, addr_tv_r, addr_tv_r[block_offset_width_lp+:lg_sets_lp], data_o);
        end
        else if (v_tv_r & store_op_tv_r & store_hit_tv & ~uncached_tv_r & ~miss_tv & ~fencei_op_tv_r) begin
          $fwrite(file, "[%t] Store hit: addr: %x index: %x data: %x\n", $time, addr_tv_r, addr_tv_r[block_offset_width_lp+:lg_sets_lp], data_tv_r);
        end
        else begin
          $fwrite(file, "[%t] Cache valid out: addr: %x index: %x data: %x\n", $time, addr_tv_r, addr_tv_r[block_offset_width_lp+:lg_sets_lp], data_o);
        end
      end

      // Cache Misses
      if (cache_req_v_o)
        $fwrite(file, "[%t] Cache Miss Request: %s addr: %x data: %x\n", $time, op, cache_req_cast_o.addr, cache_req_cast_o.data);

      if (cache_req_v_o & (cache_req_cast_o.msg_type == e_miss_store || cache_req_cast_o.msg_type == e_uc_store))
        $fwrite(file, "[%t] store data: %x\n", $time, data_tv_r);

      if (cache_req_metadata_v_o)
        $fwrite(file, "[%t] lru_way: %x dirty: %x\n", $time, cache_req_metadata_cast_o.repl_way, cache_req_metadata_cast_o.dirty);

      if (cache_req_complete_i)
        $fwrite(file, "[%t] Cache request completed\n", $time);

      // LR/SC
      if (lr_hit_tv)
        $fwrite(file, "[%t] LR Hit!\n", $time);

      if (lr_miss_tv)
        $fwrite(file, "[%t] LR Miss!\n", $time);

      if (sc_success)
        $fwrite(file, "[%t] SC SUCCESS!\n", $time);

      if (sc_fail)
        $fwrite(file, "[%t] SC FAIL!\n", $time);

      // Data, Tag, and Stat mem packets
      if (data_mem_pkt_yumi_o)
        $fwrite(file, "[%t] Data Mem: op: %s index: %x way: %x  data: %x\n", $time, data_op, data_mem_pkt_cast_i.index, data_mem_pkt_cast_i.way_id, data_mem_pkt_cast_i.data);

      if (tag_mem_pkt_yumi_o)
        $fwrite(file, "[%t] Tag Mem: op: %s index: %x way: %x tag: %x state: %x\n", $time, tag_op, tag_mem_pkt_cast_i.index, tag_mem_pkt_cast_i.way_id, tag_mem_pkt_cast_i.tag, tag_mem_pkt_cast_i.state);

      if (stat_mem_pkt_yumi_o)
        $fwrite(file, "[%t] Stat Mem: op: %s, index: %x way: %x\n", $time, stat_op, stat_mem_pkt_cast_i.index, stat_mem_pkt_cast_i.way_id);

    end

endmodule
