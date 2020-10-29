import os

from cryptol import CryptolConnection, CryptolContext, cry
import cryptol
import cryptol.cryptoltypes
from BitVector import *

dir_path = os.path.dirname(os.path.realpath(__file__))

c = cryptol.connect("cabal new-exec --verbose=0 cryptol-remote-api")

c.change_directory(dir_path)

c.load_file("Foo.cry")

x_val = c.evaluate_expression("x").result()

bits_5 = [BitVector(size=5, intVal = n) for n in range(0,3)]
result = c.call('fives', c.call('fives', bits_5).result()).result()
assert result == bits_5

assert c.evaluate_expression("Id::id x").result() == x_val
assert c.call('Id::id', bytes.fromhex('ff')).result() == BitVector(rawbytes=bytes.fromhex('ff'))


assert c.call('add', b'\0', b'\1').result() == BitVector(rawbytes=b'\1')
assert c.call('add', bytes.fromhex('ff'), bytes.fromhex('03')).result() == BitVector(rawbytes=bytes.fromhex('02'))



cryptol.add_cryptol_module('Foo', c)
from Foo import *
assert add(b'\2', 2) == BitVector(rawbytes=b'\4')

assert add(BitVector( intVal = 0, size = 8 ), BitVector( intVal = 1, size = 8 )) == BitVector(rawbytes=bytes.fromhex('01'))
assert add(BitVector( intVal = 1, size = 8 ), BitVector( intVal = 2, size = 8 )) == BitVector(rawbytes=bytes.fromhex('03'))
assert add(BitVector( intVal = 255, size = 8 ), BitVector( intVal = 1, size = 8 )) == BitVector(rawbytes=bytes.fromhex('00'))

for i in range(0,512):
    for j in range(0,512):
        bv8_1 = BitVector(intVal=i % 256, size=8)
        bv8_2 = BitVector(intVal=j % 256, size=8)
        bv9_1 = BitVector(intVal=i, size=9)
        bv9_2 = BitVector(intVal=j, size=9)
        assert add(bv8_1, bv8_2) == bv8_1 + bv8_2
        assert add(bv9_1, bv9_2) == bv9_1 + bv9_2
