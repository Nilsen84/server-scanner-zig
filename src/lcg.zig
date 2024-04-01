const std = @import("std");

// https://en.wikipedia.org/wiki/Linear_congruential_generator#m_a_power_of_2,_c_%E2%89%A0_0
pub fn FullCycleLCG(comptime T: type) type {
    return struct {
        a: T,
        c: T,
        state: T,

        pub fn init(rand: std.Random) @This() {
            return .{
                .a = rand.int(T) & ~@as(T, 0b111) | 0b101, // a ≡ 5 (mod 8)
                .c = rand.int(T) | 0b1, // coprime with M (only has to be odd since M is a power of 2),
                .state = rand.int(T),
            };
        }

        pub fn next(self: *@This()) T {
            self.state = self.state *% self.a +% self.c;
            return self.state;
        }
    };
}
