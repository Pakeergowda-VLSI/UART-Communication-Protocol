# UART Communication Protocol – VLSI Implementation
## Complete Technical Report

---

## 1. Project Overview

This project implements a **Universal Asynchronous Receiver/Transmitter (UART)** serial communication
protocol entirely in **Verilog HDL** for VLSI / FPGA synthesis. The design is fully parameterised,
RTL-clean, and verified by a self-checking testbench.

| Property | Value |
|---|---|
| Language | Verilog-2005 / SystemVerilog |
| Clock | 50 MHz (configurable) |
| Default Baud Rate | 9600 (configurable) |
| Data Bits | 8 (configurable: 7–8) |
| Stop Bits | 1 or 2 (configurable) |
| Parity | None / Even / Odd (configurable) |
| FIFO Depth | 16 entries (configurable, must be 2^N) |
| RX Oversampling | 16× with majority-vote noise filter |
| Simulation Tool | Icarus Verilog (iverilog / vvp) |

---

## 2. UART Protocol Background

UART is an **asynchronous** serial protocol — no clock line is shared between sender and receiver.
Instead, both ends agree on a **baud rate** (bits per second) beforehand.

### 2.1 Frame Format

```
 IDLE  START  D0  D1  D2  D3  D4  D5  D6  D7  [PAR]  STOP  IDLE
  1     0     ?   ?   ?   ?   ?   ?   ?   ?    ?       1     1
```

| Bit | Level | Duration |
|---|---|---|
| Idle | HIGH (1) | Until transmission starts |
| Start bit | LOW (0) | 1 bit period |
| Data bits (D0–D7) | LSB first | 8 × bit period |
| Parity bit (optional) | XOR of data | 1 bit period |
| Stop bit(s) | HIGH (1) | 1 or 2 bit periods |

### 2.2 Baud Rate & Bit Period

```
Bit Period  = 1 / Baud Rate
              = 1 / 9600
              ≈ 104.167 µs  (at 9600 baud)

Baud Divider = System Clock / Baud Rate
             = 50,000,000 / 9600
             ≈ 5208 clock cycles per bit
```

---

## 3. Architecture

```
                ┌────────────────────────────────────────────┐
                │              uart_top.v                    │
  Reg Bus ──►──┤                                            │
  (addr/data)  │  ┌──────────────┐    ┌──────────────┐     │
               │  │  uart_baud_  │    │  uart_fifo   │     │──► uart_tx (serial out)
               │  │  gen.v       │    │  (TX FIFO)   │     │
               │  │              │    └──────┬───────┘     │
               │  │  baud_tick ──┼──────────►│             │
               │  │  baud_tick   │           ▼             │
               │  │  x16     ───┼──► uart_tx.v             │
               │  └──────────────┘                         │
               │                    ┌──────────────┐       │◄── uart_rx (serial in)
               │                    │  uart_fifo   │       │
               │                    │  (RX FIFO)   │       │
               │                    └──────┬───────┘       │
               │                          ▲                │
               │                    uart_rx.v              │
               │                    (16× oversample)       │
               └────────────────────────────────────────────┘
```

### Module Breakdown

| Module | File | Function |
|---|---|---|
| `uart_baud_gen` | `rtl/uart_baud_gen.v` | Clock divider producing baud_tick and baud_tick_x16 |
| `uart_tx` | `rtl/uart_tx.v` | Serial transmitter FSM |
| `uart_rx` | `rtl/uart_rx.v` | Serial receiver with 16× oversampling |
| `uart_fifo` | `rtl/uart_fifo.v` | Parameterised synchronous FIFO |
| `uart_top` | `rtl/uart_top.v` | Top-level integrator + register interface |

---

## 4. Module Details

### 4.1 Baud Rate Generator (`uart_baud_gen.v`)

Generates two periodic pulse signals:
- **`baud_tick`** — 1 pulse every `CLK_FREQ/BAUD_RATE` cycles → used by TX
- **`baud_tick_x16`** — 1 pulse every `CLK_FREQ/(BAUD_RATE×16)` cycles → used by RX oversampling

```
CLK  ─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─
      └─┘ └─┘ └─┘ └─┘ └─┘ └─┘ └─┘ └─┘ └─┘

baud_tick_x16 fires every 325 clocks (at 50MHz/9600/16)
baud_tick     fires every 5208 clocks (at 50MHz/9600)
```

### 4.2 UART Transmitter FSM (`uart_tx.v`)

States: `IDLE → START → DATA → [PARITY] → STOP → IDLE`

```
        tx_valid &
        tx_ready
  IDLE ──────────► START ──► DATA ──► [PARITY] ──► STOP
   ▲                                               │
   └───────────────────────────────────────────────┘
              (after STOP_BITS stop bits)
```

Key design points:
- Line held HIGH in IDLE and STOP states
- Data loaded from register into shift register on entry
- LSB shifted out first, register right-shifted each baud_tick
- `tx_ready` de-asserted during transmission

### 4.3 UART Receiver FSM (`uart_rx.v`)

States: `IDLE → START → DATA → [PARITY] → STOP → IDLE`

**16× Oversampling strategy:**
- Each bit is sampled 16 times
- Falling edge of RX line detected → counter starts
- Sampling occurs at ticks 7, 8, 9 of each 16-tick window (centre third)
- **Majority vote** of the 3 samples used → immune to single-point noise

```
|<─────────── 1 bit period ───────────►|
  0  1  2  3  4  5  6  [7  8  9]  ...  15
                         ↑  ↑  ↑
                     majority vote
```

**2-FF synchroniser** on RX input prevents metastability.

**Error detection:**
- `rx_frame_err` — stop bit sampled as LOW
- `rx_parity_err` — computed parity does not match received parity bit

### 4.4 FIFO (`uart_fifo.v`)

- Simple synchronous FIFO with dual read/write pointers (one extra bit for full/empty)
- `full` flag prevents overflow, `empty` flag prevents underflow
- TX FIFO: written by CPU, read by TX core
- RX FIFO: written by RX core, read by CPU

### 4.5 Register Interface (`uart_top.v`)

| Address | Register | R/W | Bit Fields |
|---|---|---|---|
| 0x0 | DATA | R/W | [7:0] TX write / RX read |
| 0x1 | STATUS | R | [7]TX_FULL [6]TX_EMPTY [5]RX_FULL [4]RX_EMPTY [3]TX_BUSY [2]PAR_ERR [1]FRM_ERR [0]RX_VALID |
| 0x2 | CTRL | R/W | [1]PARITY_EN [0]LOOPBACK_EN |

---

## 5. Simulation Results

All 7 test cases passed:

| Test | Description | Result |
|---|---|---|
| 1 | Status register after reset | PASS |
| 2 | Transmit single byte (0x55) | PASS |
| 3 | Transmit 4-byte string "UART" | PASS |
| 4 | Receive byte from external stimulus (0xA5) | PASS |
| 5 | Internal loopback (TX → RX, 0xC3) | PASS |
| 6 | FIFO burst (8 bytes: '0'–'7') | PASS |
| 7 | Sequential 3-byte receive (0x11, 0x22, 0x33) | PASS |

---

## 6. How to Run

### Step 1: Compile
```bash
iverilog -g2012 -o simulation/uart_sim \
  rtl/uart_baud_gen.v  \
  rtl/uart_fifo.v      \
  rtl/uart_tx.v        \
  rtl/uart_rx.v        \
  rtl/uart_top.v       \
  testbench/uart_tb.v
```

### Step 2: Simulate
```bash
cd simulation
vvp uart_sim
```

### Step 3: View Waveforms (optional)
```bash
gtkwave uart_sim.vcd
```

### Step 4: Synthesise (requires Yosys)
```bash
cd simulation
yosys synth_uart.ys
```

---

## 7. Resource Estimate (FPGA – Spartan-7)

| Resource | Estimate |
|---|---|
| LUTs | ~120 |
| Flip-Flops | ~80 |
| Block RAM | 0 (distributed RAM for FIFO) |
| DSPs | 0 |
| Max Fmax | >100 MHz |

---

## 8. Customisation Parameters

```verilog
uart_top #(
    .CLK_FREQ   (50_000_000),  // System clock in Hz
    .BAUD_RATE  (115200),      // Any standard baud rate
    .DATA_BITS  (8),           // 7 or 8
    .STOP_BITS  (1),           // 1 or 2
    .PARITY_EN  (1),           // 0=None, 1=Enable
    .PARITY_ODD (0),           // 0=Even, 1=Odd
    .FIFO_DEPTH (32)           // Must be power of 2
) u_uart (...);
```

---

## 9. File Structure

```
uart_vlsi/
├── rtl/
│   ├── uart_baud_gen.v     Baud rate generator
│   ├── uart_tx.v           Transmitter FSM
│   ├── uart_rx.v           Receiver with 16× oversampling
│   ├── uart_fifo.v         Synchronous FIFO buffer
│   └── uart_top.v          Top-level + register interface
├── testbench/
│   └── uart_tb.v           Self-checking testbench (7 tests)
├── simulation/
│   ├── uart_sim            Compiled simulation binary
│   ├── uart_sim.vcd        Waveform dump (GTKWave)
│   └── synth_uart.ys       Yosys synthesis script
└── docs/
    └── UART_Report.md      This document
```

---

## 10. References

1. TIA-232 / RS-232 Standard – Serial Communications
2. UART 16550 Datasheet – National Semiconductor
3. Verilog HDL – IEEE Std 1364-2005
4. FPGA Prototyping by Verilog Examples – Pong P. Chu
