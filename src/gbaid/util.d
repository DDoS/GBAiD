module gbaid.util;

public ulong ucast(int v) {
    return cast(ulong) v & 0xFFFFFFFF;
}
