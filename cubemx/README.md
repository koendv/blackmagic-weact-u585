# STM32CubeMX reference configuration

*Written by Claude (Anthropic's AI model) during development with Koen De Vleeschauwer. Not reviewed line by
line.*

`weact-blackpill-u585ci.ioc` is an STM32CubeMX project for the WeAct Black Pill STM32U585 (STM32U585CIUx,
UFQFPN48) with the pin assignment and clock tree of the `weact-u585` firmware. `weact-blackpill-u585ci.pdf`
and `weact-blackpill-u585ci.txt` are the report CubeMX generates from it.

The build does not use these files. They are a reference: CubeMX checks pin conflicts, alternate functions
and clock limits, so plan a change here first, then carry it over by hand to the firmware, which is written
with libopencm3, not ST's HAL:

| What            | Firmware file (in `patches/blackmagic`)                                             |
| --------------- | ----------------------------------------------------------------------------------- |
| Pins            | `src/platforms/weact-u585/platform.h`, `platform.c` (patch 0001)                     |
| Clocks          | `src/platforms/weact-u585/rcc_clocking.h` (patches 0001, 0009), `platform.c`         |

## Updating

Open the `.ioc` in STM32CubeMX 6.18.1 or later, make the change, save, and regenerate the report
(*Project Manager* → *Generate Report*), then commit all three files. Generated code (`Core/`, `Drivers/`,
Makefile, linker scripts) is not kept here: CubeMX regenerates it from the `.ioc`. `.gitattributes` keeps
the files exactly as CubeMX writes them.

## Clocks

The clock tree is the one WeAct uses in its own examples for this board, see
[01-RTC.ioc](https://github.com/WeActStudio/WeActStudio.STM32U585Cx_CoreBoard/blob/master/Examples/01-RTC/01-RTC.ioc):

- SYSCLK 160MHz from PLL1 fed by the 25MHz HSE crystal: M = 5, N = 64, R = 2 (PLL1 R only divides by 1 or
  an even number), voltage scale 1, 4 Flash wait states, AHB and APB1/2/3 undivided
- USB 48MHz from HSI48, trimmed by the CRS against USB SOF
- LSE 32.768kHz crystal, drive capability medium-high

## Intentional differences from the firmware

| Pin       | In the `.ioc`          | In the firmware                                                                          |
| --------- | ---------------------- | ---------------------------------------------------------------------------------------- |
| PA0       | UART4_TX               | Not used. CubeMX's UART4 asynchronous mode always claims TX and RX; the firmware only uses UART4_RX on PA1. PA0 is the board's user key and is free to use as a GPIO. |
| PA1       | UART4_RX               | SWO input: UART4_RX for UART/NRZ, or TIM5_CH2 for Manchester capture. CubeMX can show one function only. |
| PA4       | SPI1 hardware NSS      | GPIO chip select for the on-board SPI Flash (U3).                                        |
| PB12      | SPI2 hardware NSS      | TMS/SWDIO, and a GPIO chip select while the external SPI bus is in use.                  |
| PB13-PB15 | SPI2 SCK/MISO/MOSI     | Bit-banged TCK/SWCLK, TDO, TDI; SPI2 only while the external SPI bus is in use.          |
| PB6/PB7   | I2C1                   | Not used, reserved.                                                                      |
| PB8/PB9   | FDCAN1                 | Not used, reserved.                                                                      |

The firmware also starts the HSE and LSE itself, with timeouts, and falls back to MSIS for SYSCLK if the HSE
does not start; CubeMX's generated code would stop in `Error_Handler()` instead.
