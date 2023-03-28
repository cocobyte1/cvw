///////////////////////////////////////////
// uart.sv
//
// Written: David_Harris@hmc.edu 21 January 2021
// Modified: 
//
// Purpose: Universial Asynchronous Receiver/ Transmitter with FIFOs
//          Emulates interface of Texas Instruments PC16550D
//          https://media.digikey.com/pdf/Data%20Sheets/Texas%20Instruments%20PDFs/PC16550D.pdf
//          Compatible with UART in Imperas Virtio model ***
//
//  Compatible with most of PC16550D with the following known exceptions:
//   Generates 2 rather than 1.5 stop bits when 5-bit word length is slected and LCR[2] = 1
//   Timeout not yet implemented***
// 
// Documentation: RISC-V System on Chip Design Chapter 15
//
// A component of the CORE-V-WALLY configurable RISC-V project.
// 
// Copyright (C) 2021-23 Harvey Mudd College & Oklahoma State University
//
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the “License”); you may not use this file 
// except in compliance with the License, or, at your option, the Apache License version 2.0. You 
// may obtain a copy of the License at
//
// https://solderpad.org/licenses/SHL-2.1/
//
// Unless required by applicable law or agreed to in writing, any work distributed under the 
// License is distributed on an “AS IS” BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, 
// either express or implied. See the License for the specific language governing permissions 
// and limitations under the License.
////////////////////////////////////////////////////////////////////////////////////////////////

`include "wally-config.vh"
/* verilator lint_off UNOPTFLAT */

module uartPC16550D(
  // Processor Interface
  input  logic       PCLK, PRESETn,                  // UART clock and active low reset
  input  logic [2:0] A,                              // address input (8 registers)
  input  logic [7:0] Din,                            // 8-bit WriteData
  output logic [7:0] Dout,                           // 8-bit ReadData
  input  logic       MEMRb, MEMWb,                   // Active low memory read/write
  output logic       INTR, TXRDYb, RXRDYb,           // interrupt and ready lines
  // Clocks
  output logic       BAUDOUTb,                       // active low baud clock
  input logic         RCLK,                           // usually BAUDOUTb tied to RCLK externally
  // E1A Driver
  input  logic       SIN, DSRb, DCDb, CTSb, RIb,     // UART external serial and flow-control inputs
  output logic       SOUT, RTSb, DTRb, OUT1b, OUT2b  // UART external serial and flow-control outputs
);

  // transmit and receive states 
  typedef enum logic [1:0] {UART_IDLE, UART_ACTIVE, UART_DONE, UART_BREAK} statetype;

  // Registers
  logic [10:0] RBR;
  logic [7:0]  FCR, LCR, LSR, SCR, DLL, DLM;
  logic [3:0]  IER, MSR;
  logic [4:0]  MCR;

  // Syncrhonized and delayed UART signals
  logic        SINd, DSRbd, DCDbd, CTSbd, RIbd;
  logic        SINsync, DSRbsync, DCDbsync, CTSbsync, RIbsync;
  logic        DSRb2, DCDb2, CTSb2, RIb2;
  logic        SOUTbit;

  // Control signals
  logic        loop; // loopback mode
  logic        DLAB; // Divisor Latch Access Bit (LCR bit 7)

  // Baud and rx/tx timing
  logic        baudpulse, txbaudpulse, rxbaudpulse; // high one system clk cycle each baud/16 period
  logic [16+`UART_PRESCALE-1:0] baudcount;
  logic [3:0]                   rxoversampledcnt, txoversampledcnt; // count oversampled-by-16
  logic [3:0]                   rxbitsreceived, txbitssent;
  statetype rxstate, txstate;

  // shift registrs and FIFOs
  logic [9:0]                   rxshiftreg;
  logic [10:0]                  rxfifo[15:0];
  logic [7:0]                   txfifo[15:0];
  logic [4:0]                   rxfifotailunwrapped;
  logic [3:0]                   rxfifohead, rxfifotail, txfifohead, txfifotail, rxfifotriggerlevel;
  logic [3:0]                   rxfifoentries, txfifoentries;
  logic [3:0]                   rxbitsexpected, txbitsexpected;

  // receive data
  logic [10:0]                  RXBR;
  logic [9:0]                   rxtimeoutcnt;
  logic                         rxcentered;
  logic                         rxparity, rxparitybit, rxstopbit;
  logic                         rxparityerr, rxoverrunerr, rxframingerr, rxbreak, rxfifohaserr;
  logic                         rxdataready;
  logic                         rxfifoempty, rxfifotriggered, rxfifotimeout;
  logic                         rxfifodmaready;
  logic [8:0]                   rxdata9;
  logic [7:0]                   rxdata;
  logic [15:0]                  RXerrbit, rxfullbit;
  logic [31:0]                  rxfullbitunwrapped;

  // transmit data
  logic [7:0]                   TXHR, nexttxdata;
  logic [11:0]                  txdata, txsr;
  logic                         txnextbit, txhrfull, txsrfull;
  logic                         txparity;
  logic                         txfifoempty, txfifofull, txfifodmaready;

  // control signals
  logic                         fifoenabled, fifodmamodesel, evenparitysel;

  // interrupts
  logic                         RXerr, RXerrIP, squashRXerrIP, prevSquashRXerrIP, setSquashRXerrIP, resetSquashRXerrIP;
  logic                         THRE, THRE_IP, squashTHRE_IP, prevSquashTHRE_IP, setSquashTHRE_IP, resetSquashTHRE_IP;
  logic                         rxdataavailintr, modemstatusintr, intrpending;
  logic [2:0]                   intrID;

  logic                         baudpulseComb;
  logic                         HeadPointerLastMove;

  ///////////////////////////////////////////
  // Input synchronization: 2-stage synchronizer
  ///////////////////////////////////////////
  always_ff @(posedge PCLK) begin
    {SINd, DSRbd, DCDbd, CTSbd, RIbd} <= #1 {SIN, DSRb, DCDb, CTSb, RIb};
    {SINsync, DSRbsync, DCDbsync, CTSbsync, RIbsync} <= #1 loop ? {SOUTbit, ~MCR[0], ~MCR[3], ~MCR[1], ~MCR[2]} : 
                            {SINd, DSRbd, DCDbd, CTSbd, RIbd}; // syncrhonized signals, handle loopback testing
    {DSRb2, DCDb2, CTSb2, RIb2} <= #1 {DSRbsync, DCDbsync, CTSbsync, RIbsync}; // for detecting state changes
  end

  ///////////////////////////////////////////
  // Register interface (Table 1, note some are read only and some write only)
  ///////////////////////////////////////////
  always_ff @(posedge PCLK, negedge PRESETn) 
    if (~PRESETn) begin // Table 3 Reset Configuration
      IER <= #1 4'b0;
      FCR <= #1 8'b0;
      if (`QEMU) LCR <= #1 8'b0; else LCR <= #1 8'b11; // fpga only **** BUG
      MCR <= #1 5'b0;
      LSR <= #1 8'b01100000;
      MSR <= #1 4'b0;
      DLL <= #1 8'd1; // this cannot be zero with DLM also zer0.
      DLM <= #1 8'b0;
      SCR <= #1 8'b0; // not strictly necessary to reset
    end else begin
      if (~MEMWb) begin
        /* verilator lint_off CASEINCOMPLETE */
        case (A)
          3'b000: if (DLAB) DLL <= #1 Din; // else TXHR <= #1 Din; // TX handled in TX register/FIFO section
          3'b001: if (DLAB) DLM <= #1 Din; else IER <= #1 Din[3:0];
          3'b010: FCR <= #1 {Din[7:6], 2'b0, Din[3], 2'b0, Din[0]}; // Write only FIFO Control Register; 4:5 reserved and 2:1 self-clearing
          3'b011: LCR <= #1 Din;
          3'b100: MCR <= #1 Din[4:0];
          3'b111: SCR <= #1 Din;
        endcase
        /* verilator lint_on CASEINCOMPLETE */
      end

      // Line Status Register (8.6.3)
      // Ben 6/9/21 I don't like how this is a register. A lot of the individual bits have clocked components, so this just adds unecessary delay.
      if (~MEMWb & (A == 3'b101))
        LSR[6:1] <= #1 Din[6:1]; // recommended only for test, see 8.6.3
      else begin
        LSR[0] <= #1 rxdataready; // Data ready
        LSR[1] <= #1 (LSR[1] | RXBR[10]) & ~squashRXerrIP;; // overrun error
        LSR[2] <= #1 (LSR[2] | RXBR[9]) & ~squashRXerrIP; // parity error
        LSR[3] <= #1 (LSR[3] | RXBR[8]) & ~squashRXerrIP; // framing error
        LSR[4] <= #1 (LSR[4] | rxbreak) & ~squashRXerrIP; // break indicator
        LSR[5] <= #1 THRE; // THRE
        LSR[6] <= #1 ~txsrfull & THRE; //  TEMT
        if (rxfifohaserr) LSR[7] <= #1 1; // any bits in FIFO have error
      end

      // Modem Status Register (8.6.8)
      if (~MEMWb & (A == 3'b110))
        MSR <= #1 Din[3:0];
      else if (~MEMRb & (A == 3'b110)) 
        MSR <= #1 4'b0; // Reading MSR clears the flags in MSR bits 3:0
      else begin
        MSR[0] <= #1 MSR[0] | CTSb2 ^ CTSbsync; // Delta Clear to Send
        MSR[1] <= #1 MSR[1] | DSRb2 ^ DSRbsync; // Delta Data Set Ready
        MSR[2] <= #1 MSR[2] | (~RIb2 & RIbsync); // Trailing Edge of Ring Indicator
        MSR[3] <= #1 MSR[3] | DCDb2 ^ DCDbsync; // Delta Data Carrier Detect
      end
    end
  always_comb
    if (~MEMRb)
      case (A)
        3'b000: if (DLAB) Dout = DLL; else Dout = RBR[7:0];
        3'b001: if (DLAB) Dout = DLM; else Dout = {4'b0, IER[3:0]};
        3'b010: Dout = {{2{fifoenabled}}, 2'b00, intrID[2:0], ~intrpending}; // Read only Interupt Ident Register
        3'b011: Dout = LCR;
        3'b100: Dout = {3'b000, MCR};
        3'b101: Dout = LSR;
        // 3'b110: Dout = {~CTSbsync, ~DSRbsync, ~RIbsync, ~DCDbsync, MSR[3:0]}; 
        3'b110: Dout = {~DCDbsync, ~RIbsync, ~DSRbsync, ~CTSbsync, MSR[3:0]};
        3'b111: Dout = SCR;      
      endcase
    else Dout = 8'b0;

  ///////////////////////////////////////////
  // Baud rate generator
  // consider switching to same fixed-frequency reference clock used for TIME register
  // prescale by factor of 2^UART_PRESCALE to allow for high-frequency reference clock
  // Unlike PC16550D, this unit is hardwired with same rx and tx baud clock
  // *** add table of scale factors to get 16x uart clk
  ///////////////////////////////////////////
  // Ross Thompson: Found a bug.  If the baud rate dividers DLM, and DLL are reloaded
  // the baudcount is not reset to  {DLM, DLL, UART_PRESCALE}
  always_ff @(posedge PCLK, negedge PRESETn) 
    if (~PRESETn) begin
      baudcount <= #1 1;
      baudpulse <= #1 0;
    end else if (~MEMWb & DLAB & (A == 3'b0 | A == 3'b1)) begin
      baudcount <= #1 1;
    end else begin
      // the baudpulse is too long by 2 clock cycles.
      // This is cause baudpulse is registered adding 1 cycle and
      // baudcount is reset when baudcount equals the threshold {DLM, DLL, UART_PRESCALE}
      // rather than 1 less than that value.  Alternatively the reset value could be 1 rather 
      // than 0.
      baudpulse <= #1 baudpulseComb;
      baudcount <= #1 baudpulseComb ? 1 :  baudcount +1;
    end

  assign baudpulseComb = (baudcount == {DLM, DLL, {(`UART_PRESCALE){1'b0}}});
  
  assign txbaudpulse = baudpulse;
  assign BAUDOUTb = ~baudpulse;
  assign rxbaudpulse = ~RCLK; // usually BAUDOUTb tied to RCLK externally

  ///////////////////////////////////////////
  // receive timing and control
  ///////////////////////////////////////////
  always_ff @(posedge PCLK, negedge PRESETn)
    if (~PRESETn) begin
      rxoversampledcnt <= #1 0;
      rxstate <= #1 UART_IDLE;
      rxbitsreceived <= #1 0;
      rxtimeoutcnt <= #1 0;
    end else begin
      if (rxstate == UART_IDLE & ~SINsync) begin // got start bit
        rxstate <= #1 UART_ACTIVE;
        rxoversampledcnt <= #1 0;
        rxbitsreceived <= #1 0;
        if (~rxfifotimeout) rxtimeoutcnt <= #1 0; // reset timeout when new character is arriving. Jacob Pease: Only if the timeout was not already reached. p.16 PC16550D.pdf
      end else if (rxbaudpulse & (rxstate == UART_ACTIVE)) begin
        rxoversampledcnt <= #1 rxoversampledcnt + 1;  // 16x oversampled counter
        if (rxcentered) rxbitsreceived <= #1 rxbitsreceived + 1;
        if (rxbitsreceived == rxbitsexpected) rxstate <= #1 UART_DONE; // pulse rxdone for a cycle
      end else if (rxstate == UART_DONE | rxstate == UART_BREAK) begin
        if (rxbreak & ~SINsync) rxstate <= #1 UART_BREAK;
        else rxstate <= #1 UART_IDLE;
      end
      // timeout counting
      if (~MEMRb & A == 3'b000 & ~DLAB) rxtimeoutcnt <= #1 0; // reset timeout on read
      else if (fifoenabled & ~rxfifoempty & rxbaudpulse & ~rxfifotimeout) rxtimeoutcnt <= #1 rxtimeoutcnt+1; // *** not right
    end

  // ***explain why
  if(`QEMU) assign rxcentered = rxbaudpulse & (rxoversampledcnt[1:0] == 2'b10);  // implies rxstate = UART_ACTIVE
  else      assign rxcentered = rxbaudpulse & (rxoversampledcnt == 4'b1000);     // implies rxstate = UART_ACTIVE      
 
  assign rxbitsexpected = 4'd1 + (4'd5 + {2'b00, LCR[1:0]}) + {3'b000, LCR[3]} + 4'd1; // start bit + data bits + (parity bit) + stop bit 
  
  ///////////////////////////////////////////
  // receive shift register, buffer register, FIFO
  ///////////////////////////////////////////
  always_ff @(posedge PCLK, negedge PRESETn)
    if (~PRESETn) rxshiftreg <= #1 10'b0000000001; // initialize so that there is a valid stop bit
    else if (rxcentered) rxshiftreg <= #1 {rxshiftreg[8:0], SINsync}; // capture bit
  assign rxparitybit = rxshiftreg[1]; // parity, if it exists, in bit 1 when all done
  assign rxstopbit = rxshiftreg[0];
  always_comb
    case(LCR[1:0]) // check how many bits used.  Grab all bits including possible parity
      2'b00: rxdata9 = {3'b0, rxshiftreg[1], rxshiftreg[2], rxshiftreg[3], rxshiftreg[4], rxshiftreg[5], rxshiftreg[6]}; // 5-bit character
      2'b01: rxdata9 = {2'b0, rxshiftreg[1], rxshiftreg[2], rxshiftreg[3], rxshiftreg[4], rxshiftreg[5], rxshiftreg[6], rxshiftreg[7]}; // 6-bit 
      2'b10: rxdata9 = {1'b0, rxshiftreg[1], rxshiftreg[2], rxshiftreg[3], rxshiftreg[4], rxshiftreg[5], rxshiftreg[6], rxshiftreg[7], rxshiftreg[8]}; // 7-bit
      2'b11: rxdata9 = {      rxshiftreg[1], rxshiftreg[2], rxshiftreg[3], rxshiftreg[4], rxshiftreg[5], rxshiftreg[6], rxshiftreg[7], rxshiftreg[8], rxshiftreg[9]}; // 8-bit
    endcase
  assign rxdata = LCR[3] ? rxdata9[7:0] : rxdata9[8:1]; // discard parity bit

  // ERROR CONDITIONS
  assign rxparity = ^rxdata;
  assign rxparityerr = (rxparity ^ rxparitybit ^ ~evenparitysel) & LCR[3]; // Check even/odd parity (*** check if LCR needs to be inverted)
  assign rxoverrunerr = fifoenabled ? (rxfifoentries == 15) : rxdataready; // overrun if FIFO or receive buffer register full 
  assign rxframingerr = ~rxstopbit; // framing error if no stop bit
  assign rxbreak = rxframingerr & (rxdata9 == 9'b0); // break when 0 for start + data + parity + stop time

  // receive FIFO and register
  always_ff @(posedge PCLK)
    if (~PRESETn) begin
      rxfifohead <= #1 0; rxfifotail <= #1 0; rxdataready <= #1 0; RXBR <= #1 0;
    end else begin
      if (~MEMWb & (A == 3'b010) & Din[1]) begin
        rxfifohead <= #1 0; rxfifotail <= #1 0; rxdataready <= #1 0;
      end else if (rxstate == UART_DONE) begin
        RXBR <= #1 {rxoverrunerr, rxparityerr, rxframingerr, rxdata}; // load recevive buffer register
        if (rxoverrunerr) $warning("UART RX Overrun Err\n");
        if (rxparityerr) $warning("UART RX Parity Err\n");
        if (rxframingerr) $warning("UART RX Framing Err\n");
        if (fifoenabled) begin
          rxfifo[rxfifohead] <= #1 {rxoverrunerr, rxparityerr, rxframingerr, rxdata};
          rxfifohead <= #1 rxfifohead + 1;
        end
        rxdataready <= #1 1;
      end else if (~MEMRb & A == 3'b000 & ~DLAB) begin // reading RBR updates ready / pops fifo 
        if (fifoenabled) begin
          if (~rxfifoempty) rxfifotail <= #1 rxfifotail + 1;
          // if (rxfifoempty) rxdataready <= #1 0;
          if (rxfifoentries == 1) rxdataready <= #1 0; // When reading the last entry, data ready becomes zero
        end else begin
          rxdataready <= #1 0;
          RXBR <= #1 {1'b0, RXBR[9:0]}; // Ben 31 March 2022: I added this so that rxoverrunerr permanently goes away upon reading RBR (when not in FIFO mode)
        end
      end else if (~MEMWb & A == 3'b010)  // writes to FIFO Control Register
        if (Din[1] | ~Din[0]) begin // rx FIFO reset or FIFO disable clears FIFO contents
          rxfifohead <= #1 0; rxfifotail <= #1 0;
        end
    end

  assign rxfifoempty = (rxfifohead == rxfifotail);
  // verilator lint_off WIDTH
  assign rxfifoentries = (rxfifohead >= rxfifotail) ? (rxfifohead-rxfifotail) : 
                         (rxfifohead + 16 - rxfifotail);
  // verilator lint_on WIDTH
  assign rxfifotriggered = rxfifoentries >= rxfifotriggerlevel;
  assign rxfifotimeout = rxtimeoutcnt == {rxbitsexpected, 6'b0}; // time out after 4 character periods; *** probably not right yet
  //assign rxfifotimeout = 0; // disabled pending fix

  // detect any errors in rx fifo
  // although rxfullbit looks like a combinational loop, in one bit rxfifotail == i and breaks the loop
  // tail is normally higher than head, but might wrap around.  unwrapped variable adds 16 to eliminate wrapping
  assign rxfifotailunwrapped = rxfifotail < rxfifohead ? {1'b1, rxfifotail} : {1'b0, rxfifotail};
  genvar i;
  for (i=0; i<32; i++) begin:rxfull
    if (i == 0) assign rxfullbitunwrapped[i] = (rxfifohead==0) & (rxfifotail != 0);
    else        assign rxfullbitunwrapped[i] = ({1'b0,rxfifohead}==i | rxfullbitunwrapped[i-1]) & (rxfifotailunwrapped != i);
  end
  for (i=0; i<16; i++) begin:rx
    assign RXerrbit[i] = |rxfifo[i][10:8]; // are any of the error conditions set?
    assign rxfullbit[i] = rxfullbitunwrapped[i] | rxfullbitunwrapped[i+16];
  /*      if (i > 0)
      assign rxfullbit[i] = ((rxfifohead==i) | rxfullbit[i-1]) & (rxfifotail != i);
      else
      assign rxfullbit[0] = ((rxfifohead==i) | rxfullbit[15]) & (rxfifotail != i);*/
  end
  assign rxfifohaserr = |(RXerrbit & rxfullbit);

  // receive buffer register and ready bit
  always_ff @(posedge PCLK, negedge PRESETn) // track rxrdy for DMA mode (FCR3 = FCR0 = 1)
    if (~PRESETn) rxfifodmaready <= #1 0;
    else if (rxfifotriggered | rxfifotimeout) rxfifodmaready <= #1 1;
    else if (rxfifoempty) rxfifodmaready <= #1 0;

  always_comb
    if (fifoenabled) begin
      if (rxfifoempty) RBR = 11'b0;
      else             RBR = rxfifo[rxfifotail];
      if (fifodmamodesel) RXRDYb = ~rxfifodmaready;
      else                RXRDYb = rxfifoempty;
    end else begin
      RBR = RXBR;
      RXRDYb = ~rxdataready;
    end

  ///////////////////////////////////////////
  // transmit timing and control
  ///////////////////////////////////////////
  always_ff @(posedge PCLK, negedge PRESETn)
    if (~PRESETn) begin
      txoversampledcnt <= #1 0;
      txstate <= #1 UART_IDLE;
      txbitssent <= #1 0;
    end else if ((txstate == UART_IDLE) & txsrfull) begin // start transmitting
      txstate <= #1 UART_ACTIVE;
      txoversampledcnt <= #1 1;
      txbitssent <= #1 0;
    end else if (txbaudpulse & (txstate == UART_ACTIVE)) begin
      txoversampledcnt <= #1 txoversampledcnt + 1; 
      if (txnextbit) begin // transmit at end of phase
        txbitssent <= #1 txbitssent+1;
        if (txbitssent == txbitsexpected) txstate <= #1 UART_DONE;
      end
    end else if (txstate == UART_DONE) begin
      txstate <= #1 UART_IDLE;
    end

  assign txbitsexpected = 4'd1 + (4'd5 + {2'b00, LCR[1:0]}) + {3'b000, LCR[3]} + 4'd1 + {3'b000, LCR[2]} - 4'd1; // start bit + data bits + (parity bit) + stop bit(s) - 1
  // *** explain; is this necessary?
  if (`QEMU) assign txnextbit = txbaudpulse & (txoversampledcnt[1:0] == 2'b00);  // implies txstate = UART_ACTIVE
  else       assign txnextbit = txbaudpulse & (txoversampledcnt == 4'b0000);  // implies txstate = UART_ACTIVE

  ///////////////////////////////////////////
  // transmit holding register, shift register, FIFO
  ///////////////////////////////////////////
  always_comb begin // compute value for parity and tx holding register
    nexttxdata = fifoenabled ? txfifo[txfifotail] : TXHR; // pick from FIFO or holding register
    case (LCR[1:0]) // compute parity from appropriate number of bits
      2'b00: txparity = ^nexttxdata[4:0] ^ ~evenparitysel; // *** check polarity
      2'b01: txparity = ^nexttxdata[5:0] ^ ~evenparitysel; 
      2'b10: txparity = ^nexttxdata[6:0] ^ ~evenparitysel; 
      2'b11: txparity = ^nexttxdata[7:0] ^ ~evenparitysel; 
    endcase
    case({LCR[3], LCR[1:0]}) // parity, data bits
      // load up start bit (0), 5-8 data bits, 0-1 parity bits, 2 stop bits (only one sometimes used), padding
      3'b000: txdata = {1'b0, nexttxdata[0], nexttxdata[1], nexttxdata[2], nexttxdata[3], nexttxdata[4], 6'b111111};                                                       // 5 data, no parity
      3'b001: txdata = {1'b0, nexttxdata[0], nexttxdata[1], nexttxdata[2], nexttxdata[3], nexttxdata[4], nexttxdata[5], 5'b11111};                                         // 6 data, no parity
      3'b010: txdata = {1'b0, nexttxdata[0], nexttxdata[1], nexttxdata[2], nexttxdata[3], nexttxdata[4], nexttxdata[5], nexttxdata[6], 4'b1111};                           // 7 data, no parity
      3'b011: txdata = {1'b0, nexttxdata[0], nexttxdata[1], nexttxdata[2], nexttxdata[3], nexttxdata[4], nexttxdata[5], nexttxdata[6], nexttxdata[7], 3'b111};             // 8 data, no parity
      3'b100: txdata = {1'b0, nexttxdata[0], nexttxdata[1], nexttxdata[2], nexttxdata[3], nexttxdata[4], txparity, 5'b11111};                                              // 5 data, parity
      3'b101: txdata = {1'b0, nexttxdata[0], nexttxdata[1], nexttxdata[2], nexttxdata[3], nexttxdata[4], nexttxdata[5], txparity, 4'b1111};                                // 6 data, parity
      3'b110: txdata = {1'b0, nexttxdata[0], nexttxdata[1], nexttxdata[2], nexttxdata[3], nexttxdata[4], nexttxdata[5], nexttxdata[6], txparity, 3'b111};                  // 7 data, parity
      3'b111: txdata = {1'b0, nexttxdata[0], nexttxdata[1], nexttxdata[2], nexttxdata[3], nexttxdata[4], nexttxdata[5], nexttxdata[6], nexttxdata[7], txparity, 2'b11};    // 8 data, parity
    endcase
  end
  
  // registers & FIFO
  always_ff @(posedge PCLK, negedge PRESETn)
    if (~PRESETn) begin
      txfifohead <= #1 0; txfifotail <= #1 0; txhrfull <= #1 0; txsrfull <= #1 0; TXHR <= #1 0; txsr <= #1 12'hfff;
    end else if (~MEMWb & (A == 3'b010) & Din[2]) begin
      txfifohead <= #1 0; txfifotail <= #1 0;
    end else begin
      if (~MEMWb & A == 3'b000 & ~DLAB) begin // writing transmit holding register or fifo
        if (fifoenabled) begin
          txfifo[txfifohead] <= #1 Din;
          txfifohead <= #1 txfifohead + 1;          
        end else begin 
          TXHR <= #1 Din;
          txhrfull <= #1 1;
        end
        $write("%c",Din); // for testbench
      end
      if (txstate == UART_IDLE) begin // move data into tx shift register if available
        if (fifoenabled) begin 
          if (~txfifoempty & ~txsrfull) begin
            txsr <= #1 txdata;
            txfifotail <= #1 txfifotail+1;
            txsrfull <= #1 1;
          end
        end else if (txhrfull) begin
          txsr <= #1 txdata;
          txhrfull <= #1 0;
          txsrfull <= #1 1;
        end
      end else if (txstate == UART_DONE) txsrfull <= #1 0; // done transmitting shift register
      else if (txstate == UART_ACTIVE & txnextbit) txsr <= #1 {txsr[10:0], 1'b1}; // shift txhr
      if (!MEMWb & A == 3'b010) // writes to FIFO control register
        if (Din[2] | ~Din[0]) begin // tx FIFO reste or FIFO disable clears FIFO contents
          txfifohead <= #1 0; txfifotail <= #1 0;
        end
    end

  always_ff @(posedge PCLK, negedge PRESETn) begin
  // special condition to check if the fifo is empty or full.  Because the head
  // pointer indicates where the next write goes and not the location of the
  // current head, the head and tail pointer being equal imply two different
  // things.  First it could mean the fifo is empty and second it could mean
  // the fifo is full.  To differenciate we need to know which pointer moved
  // to cause them to be equal.  If the head pointer moved then it is full.
  // If the tail pointer moved then it is empty.  it resets to empty so
  // if reset with the tail pointer indicating the last update.
  if(~PRESETn) 
    HeadPointerLastMove <= 1'b0;
  else if(fifoenabled & ~MEMWb & A == 3'b000 & ~DLAB)
    HeadPointerLastMove <= 1'b1;
  else if(fifoenabled & ~txfifoempty & ~txsrfull & txstate == UART_IDLE)
    HeadPointerLastMove <= 1'b0;
  end

  assign txfifoempty = (txfifohead == txfifotail) & ~HeadPointerLastMove;
  // verilator lint_off WIDTH
  assign txfifoentries = (txfifohead >= txfifotail) ? (txfifohead-txfifotail) : 
                         (txfifohead + 16 - txfifotail);
  // verilator lint_on WIDTH
  //assign txfifofull = (txfifoentries == 4'b1111);
  assign txfifofull = (txfifohead == txfifotail) & HeadPointerLastMove;

  // transmit buffer ready bit
  always_ff @(posedge PCLK, negedge PRESETn) // track txrdy for DMA mode (FCR3 = FCR0 = 1)
    if (~PRESETn) txfifodmaready <= #1 0;
    else if (txfifoempty) txfifodmaready <= #1 1;
    else if (txfifofull)  txfifodmaready <= #1 0;

  always_comb
    if (fifoenabled & fifodmamodesel) TXRDYb = ~txfifodmaready;
    else TXRDYb  = ~THRE;

  // Transmitter pin 
  assign SOUTbit = txsr[11]; // transmit most significant bit
  assign SOUT = loop ? 1 : (LCR[6] ? 0 : SOUTbit); // tied to 1 during loopback or 0 during break 

  ///////////////////////////////////////////
  // interrupts
  ///////////////////////////////////////////
  assign RXerr = |LSR[4:1]; // LS interrupt if any of the flags are true
  assign RXerrIP = RXerr & ~squashRXerrIP; // intr squashed upon reading LSR
  assign rxdataavailintr = fifoenabled ? rxfifotriggered : rxdataready; 
  assign THRE = fifoenabled ? txfifoempty : ~txhrfull;
  assign THRE_IP = THRE & ~squashTHRE_IP; // THRE_IP squashed upon reading IIR
  assign modemstatusintr = |MSR[3:0]; // set interrupt when modem pins change
  
  // IIR: interrupt priority (Table 5)
  // set intrID based on highest priority pending interrupt source; otherwise, no interrupt is pending
  always_comb begin
    intrpending = 1;
    if      (RXerrIP & IER[2])                     intrID = 3'b011;
    else if (rxdataavailintr & IER[0])             intrID = 3'b010;
    else if (rxfifotimeout & fifoenabled & IER[0]) intrID = 3'b110;
    else if (THRE_IP & IER[1])                     intrID = 3'b001;
    else if (modemstatusintr & IER[3])             intrID = 3'b000;
    else begin
      intrID = 3'b000;
      intrpending = 0;
    end
  end
  always @(posedge PCLK) INTR <= #1 intrpending; // prevent glitches on interrupt pin

  // Side effect of reading LSR is lowering overrun, parity, framing, break intr's
  assign setSquashRXerrIP = ~MEMRb & (A==3'b101);
  assign resetSquashRXerrIP = (rxstate == UART_DONE);
  assign squashRXerrIP = (prevSquashRXerrIP | setSquashRXerrIP) & ~resetSquashRXerrIP;
  flopr #(1) squashRXerrIPreg(PCLK, ~PRESETn, squashRXerrIP, prevSquashRXerrIP);
  // Side effect of reading IIR is lowering THRE_IP if most significant intr
  assign setSquashTHRE_IP = ~MEMRb & (A==3'b010) & (intrID==3'h1); // there's a 1-cycle delay on set squash so that THRE_IP doesn't change during the process of reading IIR (otherwise combinational loop)
  assign resetSquashTHRE_IP = ~THRE;
  assign squashTHRE_IP = prevSquashTHRE_IP & ~resetSquashTHRE_IP;
  flopr #(1) squashTHRE_IPreg(PCLK, ~PRESETn, squashTHRE_IP | setSquashTHRE_IP, prevSquashTHRE_IP);

  ///////////////////////////////////////////
  // modem control logic
  ///////////////////////////////////////////

  assign loop = MCR[4]; 
  assign DTRb  = ~MCR[0] | loop; // disable modem signals in loopback mode
  assign RTSb  = ~MCR[1] | loop;
  assign OUT1b = ~MCR[2] | loop;
  assign OUT2b = ~MCR[3] | loop;

  assign DLAB = LCR[7];
  assign evenparitysel = LCR[4];
  assign fifoenabled = FCR[0];
  assign fifodmamodesel = FCR[3];
  always_comb
    case (FCR[7:6]) 
      2'b00: rxfifotriggerlevel = 1;
      2'b01: rxfifotriggerlevel = 4;
      2'b10: rxfifotriggerlevel = 8;
      2'b11: rxfifotriggerlevel = 14;
    endcase

endmodule

/* verilator lint_on UNOPTFLAT */
