pub const Span = struct {
    start: u32,
    end: u32,

    pub fn width(self: Span) u32 {
        return self.end - self.start;
    }

    pub fn contains(self: Span, v: u32) bool {
        return v >= self.start and v < self.end;
    }
};

pub const Position = struct { x: u32, y: u32 };
pub const Cursor = struct {
    pos: Position,
};

