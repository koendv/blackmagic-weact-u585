#!/usr/bin/env python3
# SPDX-License-Identifier: CC0-1.0
"""Probe the on-board SPI Flash of a Black Magic Debug probe with read-only commands.

Talks to the firmware over its remote protocol on the GDB serial port and prints the
JEDEC and device IDs, the status registers, the unique ID, and reads with and without
dummy bytes (03h, 0Bh) next to the SFDP area (5Ah). Nothing is written or erased.

If 0Bh Fast Read with 1 dummy byte returns the same data as 03h Read, the opcode +
3 address bytes + 8 dummy clocks framing works, and 5Ah Read SFDP, which uses the
same framing, shows the chip's real SFDP contents.

Usage: spi_probe.py [PORT]   (default /dev/ttyACM0; close GDB and bmpflash first)
Needs pyserial. Written by Claude (Anthropic's AI model), see NOTES.md.
"""
import sys

import serial

BUS = 1  # SPI_BUS_INTERNAL
DEVICE = 0  # SPI_DEVICE_INT_FLASH


def command(opcode: int, address: bool = False, dummy: int = 0) -> int:
	"""Encode a SPI Flash command as the remote protocol expects it (src/target/spi.h)"""
	return (int(address) << 11) | ((dummy & 7) << 8) | opcode


class Probe:
	def __init__(self, port: str):
		self.port = serial.Serial(port, timeout=2)

	def transfer(self, packet: str) -> str:
		self.port.write(packet.encode())
		response = b''
		while not response.endswith(b'#'):
			char = self.port.read(1)
			if not char:
				raise TimeoutError(f'no response to {packet!r} (got {response!r})')
			response += char
		return response.decode(errors='replace')

	def expect_ok(self, packet: str) -> str:
		response = self.transfer(packet)
		if not response.startswith('&K'):
			raise RuntimeError(f'{packet!r} failed: {response!r}')
		return response[2:-1]

	def read(self, opcode: int, length: int, address: int | None = None, dummy: int = 0) -> bytes:
		cmd = command(opcode, address is not None, dummy)
		return bytes.fromhex(self.expect_ok(f'!sr{BUS:02x}{DEVICE:02x}{cmd:04x}{address or 0:06x}{length:04x}#'))

	def run(self, opcode: int):
		self.expect_ok(f'!sc{BUS:02x}{DEVICE:02x}{command(opcode):04x}{0:06x}#')


def show(name: str, data: bytes):
	text = bytes(b if 32 <= b < 127 else ord('.') for b in data).decode()
	print(f'{name:32s} {data.hex(" ")}  {text}')


def main():
	probe = Probe(sys.argv[1] if len(sys.argv) > 1 else '/dev/ttyACM0')
	print('Probe:', probe.expect_ok('+#!GA#'))
	probe.expect_ok(f'!sB{BUS:02x}#')
	try:
		probe.run(0xab)  # Release Power-down, in case the Flash is in power-down
		show('9Fh JEDEC ID', probe.read(0x9f, 3))
		show('90h manufacturer/device ID', probe.read(0x90, 2, address=0))
		show('ABh device ID (3 dummy)', probe.read(0xab, 1, dummy=3))
		show('4Bh unique ID (4 dummy)', probe.read(0x4b, 8, dummy=4))
		show('05h status register 1', probe.read(0x05, 1))
		show('35h status register 2', probe.read(0x35, 1))
		show('15h status register 3', probe.read(0x15, 1))
		read = probe.read(0x03, 16, address=0)
		fast_read = probe.read(0x0b, 16, address=0, dummy=1)
		show('03h read @0', read)
		show('0Bh fast read @0 (1 dummy)', fast_read)
		sfdp = probe.read(0x5a, 256, address=0, dummy=1)
		show('5Ah SFDP @0 (1 dummy)', sfdp[:16])
		print()
		if len(set(read)) == 1:
			print('Dummy bytes: cannot tell, the Flash holds the same byte throughout @0 (provision an image first)')
		else:
			print('Dummy bytes work (0Bh == 03h):', 'yes' if fast_read == read else 'NO')
		if sfdp[:4] == b'SFDP':
			print('SFDP signature found')
		elif all(b == 0xff for b in sfdp):
			print('SFDP area blank (all 256 bytes 0xFF)')
		else:
			print('No SFDP signature')
	finally:
		probe.expect_ok(f'!sE{BUS:02x}#')


if __name__ == '__main__':
	main()
