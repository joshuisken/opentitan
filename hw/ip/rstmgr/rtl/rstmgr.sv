// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// This module is the overall reset manager wrapper
// TODO: This module is only a draft implementation that covers most of the rstmgr
// functoinality but is incomplete

`include "prim_assert.sv"

// This top level controller is fairly hardcoded right now, but will be switched to a template
module rstmgr import rstmgr_pkg::*; (
  // Primary module clocks
  input clk_i,
  input rst_ni,
  input clk_main_i,
  input clk_fixed_i,
  input clk_usb_i,

  // Bus Interface
  input tlul_pkg::tl_h2d_t tl_i,
  output tlul_pkg::tl_d2h_t tl_o,

  // pwrmgr interface
  input pwr_rst_req_t pwr_i,
  output pwr_rst_rsp_t pwr_o,

  // ast interface
  input rstmgr_ast_t ast_i,

  // cpu related inputs
  input rstmgr_cpu_t cpu_i,

  // peripheral reset requests
  input rstmgr_peri_t peri_i,

  // Interface to alert handler
  // always on resets
  output rstmgr_out_t rstmgr_o

);

  // receive POR and stretch
  // TBD
  // The por release may eventually need to be switched to a slower RTC type clock.
  // Unless the power manager's default state always requests for the fast clocks to be enabled
  // by default.

  rstmgr_por i_por (
    .clk_i,
    .rst_ni,
    .pok_i(ast_i.vcc_pok & ast_i.alw_pok),
    .rst_no(rstmgr_o.rst_por_n)
  );

  ////////////////////////////////////////////////////
  // Register Interface                             //
  ////////////////////////////////////////////////////

  rstmgr_reg_pkg::rstmgr_reg2hw_t reg2hw;
  rstmgr_reg_pkg::rstmgr_hw2reg_t hw2reg;

  rstmgr_reg_top i_reg (
    .clk_i,
    .rst_ni(rstmgr_o.rst_por_n),
    .tl_i,
    .tl_o,
    .reg2hw,
    .hw2reg,
    .devmode_i(1'b1)
  );

  ////////////////////////////////////////////////////
  // Input handling                                 //
  ////////////////////////////////////////////////////

  logic ndmreset_req_q;
  logic ndm_req_valid;

  prim_flop_2sync #(
    .Width(1),
    .ResetValue(0)
  ) i_sync (
    .clk_i,
    .rst_ni(rstmgr_o.rst_por_n),
    .d(cpu_i.ndmreset_req),
    .q(ndmreset_req_q)
  );

  assign ndm_req_valid = ndmreset_req_q & (pwr_i.reset_cause == None);

  ////////////////////////////////////////////////////
  // Source resets in the system                    //
  // These are hardcoded and not directly used.     //
  // Instead they act as async reset roots.         //
  ////////////////////////////////////////////////////
  logic [PowerDomains-1:0] rst_lc_src_n;
  logic [PowerDomains-1:0] rst_sys_src_n;

  // The two source reset modules are chained together.  The output of one is fed into the
  // the second.  This ensures that if upstream resets for any reason, the associated downstream
  // reset will also reset.

  // lc reset sources
  rstmgr_ctrl #(
    .PowerDomains(PowerDomains)
  ) i_lc_src (
    .clk_i(clk_i),
    .rst_ni(rstmgr_o.rst_por_n),
    .rst_req_i(pwr_i.rst_lc_req),
    .rst_parent_ni(PowerDomains'(1'b1)),
    .rst_no(rst_lc_src_n)
  );

  // sys reset sources
  rstmgr_ctrl #(
    .PowerDomains(PowerDomains)
  ) i_sys_src (
    .clk_i(clk_i),
    .rst_ni(rstmgr_o.rst_por_n),
    .rst_req_i(pwr_i.rst_sys_req | {PowerDomains{ndm_req_valid}}),
    .rst_parent_ni(rst_lc_src_n),
    .rst_no(rst_sys_src_n)
  );

  assign pwr_o.rst_lc_src_n = rst_lc_src_n;
  assign pwr_o.rst_sys_src_n = rst_sys_src_n;

  ////////////////////////////////////////////////////
  // leaf reset in the system                       //
  // These should all be generated                  //
  ////////////////////////////////////////////////////

  prim_flop_2sync #(
    .Width(1),
    .ResetValue(0)
  ) i_lc (
    .clk_i(clk_fixed_i),
    .rst_ni(rst_lc_src_n[ALWAYS_ON_SEL]),
    .d(1'b1),
    .q(rstmgr_o.rst_lc_n)
  );

  prim_flop_2sync #(
    .Width(1),
    .ResetValue(0)
  ) i_sys (
    .clk_i(clk_main_i),
    .rst_ni(rst_sys_src_n[ALWAYS_ON_SEL]),
    .d(1'b1),
    .q(rstmgr_o.rst_sys_n)
  );

  prim_flop_2sync #(
    .Width(1),
    .ResetValue(0)
  ) i_sys_fixed (
    .clk_i(clk_fixed_i),
    .rst_ni(rst_sys_src_n[ALWAYS_ON_SEL]),
    .d(1'b1),
    .q(rstmgr_o.rst_sys_fixed_n)
  );

  prim_flop_2sync #(
    .Width(1),
    .ResetValue(0)
  ) i_spi_device (
    .clk_i(clk_fixed_i),
    .rst_ni(rst_sys_src_n[ALWAYS_ON_SEL]),
    .d(reg2hw.rst_spi_device_n.q),
    .q(rstmgr_o.rst_spi_device_n)
  );

  prim_flop_2sync #(
    .Width(1),
    .ResetValue(0)
  ) i_usb (
    .clk_i(clk_usb_i),
    .rst_ni(rst_sys_src_n[ALWAYS_ON_SEL]),
    .d(reg2hw.rst_usb_n.q),
    .q(rstmgr_o.rst_usb_n)
  );

  ////////////////////////////////////////////////////
  // Reset info construction                        //
  ////////////////////////////////////////////////////

  logic [ResetReasons-1:0] rst_reqs;

  assign rst_reqs = {
                    ndm_req_valid,
                    (pwr_i.reset_cause == HwReq) ? peri_i.rst_reqs : ExtResetReasons'(0),
                    (pwr_i.reset_cause == LowPwrEntry)
                    };

  rstmgr_info #(
    .Reasons(ResetReasons)
  ) i_info (
    .clk_i,
    .rst_ni(rstmgr_o.rst_por_n),
    .rst_cpu_ni(cpu_i.rst_cpu_n),
    .rst_req_i(rst_reqs),
    .wr_i(reg2hw.reset_info.qe),
    .data_i(reg2hw.reset_info.q),
    .rst_reasons_o(hw2reg.reset_info)
  );

  ////////////////////////////////////////////////////
  // Assertions                                     //
  ////////////////////////////////////////////////////

  // when upstream resets, downstream must also reset

endmodule // rstmgr
