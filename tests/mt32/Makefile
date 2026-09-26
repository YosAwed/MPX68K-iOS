CXX ?= c++
MT32 = ../../X68000 Shared/MT32
SAN ?= -fsanitize=address,undefined
SOURCES = "$(MT32)/MT32Bridge.cpp" "$(MT32)"/mt32emu/*.cpp "$(MT32)/mt32emu/sha1/sha1.cpp"
.PHONY: all clean rom
all:
	$(CXX) -std=c++11 -O1 -g $(SAN) test_bridge.cpp $(SOURCES) -o /tmp/mpx68k-test-mt32
	/tmp/mpx68k-test-mt32
clean:
	rm -f /tmp/mpx68k-test-mt32 /tmp/mpx68k-test-mt32-rom

# Optional: make -C tests/mt32 rom ROM_DIR='/path/to/your/MT-32 ROM folder'
rom:
	$(CXX) -std=c++11 -O2 test_rom.cpp $(SOURCES) -o /tmp/mpx68k-test-mt32-rom
	/tmp/mpx68k-test-mt32-rom "$(ROM_DIR)"
