// Written in the D programming language.
/**
Haystack utils.

Copyright: Copyright (c) 2017, Radu Racariu <radu.racariu@gmail.com>
License:   $(LINK2 www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
Authors:   Radu Racariu
**/
module haystack.zinc.util;
import std.range.primitives :  empty, front, popFront, isInputRange;
/**
A char range that allows look ahead buffering and can also collect a buffer of items
**/
struct LookAhead(Range) if (isInputRange!Range)
{
    import core.memory              : GC;
    import std.utf                  : encode;
    import std.internal.scopebuffer : ScopeBuffer;

    this()(auto ref Range range)
    {
        this.range = range;
        initStash();
    }

    ~this()
    {
        _scratchBuf.free();
    }

    @property bool empty()
    {
        return range.empty && _scratchSlice.empty;
    }
    
    @property dchar front()
    {
        if (_scratchSlice.empty)
            return range.front;
        return _scratchSlice.front;
    }

    void popFront()
    {
        if (_scratchSlice.empty)
        {
            range.popFront();
            position++;
        }
        else
        {
            _scratchSlice = _scratchSlice[1 .. _scratchSlice.length];
        }
    }
    /// Save current stash as look ahead buffer
    void save()
    {
        if (!_scratchBuf[].empty)
            _scratchSlice = _scratchBuf[0 .. $];
    }
    /// Buffer current char
    void stash()
    {
        stash(range.front);
    }
    /// Buffer a specific char
    void stash(dchar c)
    {
        // stashing when there is an active look ahead buffer is a no op
        if (!_scratchSlice.empty)
            return;
        if (c <= 127)
        {
            _scratchBuf.put(cast(char)c);
        }
        else
        {
            char[4] parts   = void;
            auto size       = encode(parts, c);
            foreach (i; 0..size)
                _scratchBuf.put(parts[i]);
        }
    }
    /// Get the curent content of the stash
    @property const(char)[] crtStash()
    {
        return _scratchBuf[];
    }
    /// True if stash has items
    @property bool hasStash()
    {
        return !_scratchBuf[].empty;
    }
    /// Commit current stash to a string and re-init stash
    string commitStash()
    {
        auto buf = _scratchBuf[];
        GC.addRange(buf.ptr, buf.length, typeid(buf));
        initStash();
        return cast(string) buf;
    }

    /// Clears current stash
    void clearStash()
    {
        _scratchBuf.free();
        initStash();
    }
    /// True if suplied string is found in the underlying Input range
    /// If not found, it allows the StashInput to continue iteration from
    /// the original position the Input range was when the call was performed.
    bool find(string s)
    {
        if (s.empty)
            return false;
        size_t cnt;    
        while (!range.empty)
        {
            if (cnt >= s.length || s[cnt] != range.front)
                break;
            stash(range.front);
            cnt++;
            range.popFront;
        }
        bool found = (cnt == s.length);
        if (!found && hasStash) // keep look ahead buffer
            save();
        else // init stash buffer
            clearStash();
        return found;
    }

    @property ref Range range()
    {
        return _range;
    }

    @property void range(ref Range range)
    {
        this._range = range;
    }

    // members
private:

    void initStash()
    {
        _scratchBuf     = ScopeBuffer!char();
        _scratchSlice   = _scratchBuf[];
    }

    // The underlying Input range that is iterated
    Range _range                    = void;
    // Char count
    size_t position                 = -1;
    // A slice on the stash, allows to create a look ahead buffer
    char[] _scratchSlice            = void;
    // Scope buffer used for stashing items
    ScopeBuffer!char _scratchBuf    = void;
}
unittest
{
    alias Buf = LookAhead!string;
    auto buf = Buf("123456789");
    assert(buf.front == '1');
    buf.stash();
    buf.save();
    assert(buf.crtStash == "1");
    buf.popFront();
    assert(buf.front == '1');
    buf.popFront();
    assert(buf.front == '2');
    buf.clearStash();
    foreach (i; 0..3)
    {
        buf.stash();
        buf.popFront();
    }
    assert(buf.crtStash == "234");
    buf.save();
    foreach (i; 0..3)
    {
        assert(buf.front == '0' + i + 2);
        buf.popFront();
    }
}

/**
Owns the type T memory ensuring that it is not copyable
and that T constructed memory is freed and T is destroyed at end of scope.
*/
struct Own(T) if (is (T == struct))
{
    import core.memory      : GC;
    import std.conv         : emplace;
    import std.typecons     : Proxy;
    import std.algorithm    : moveEmplace;
    import std.traits       : hasIndirections;
    import core.stdc.stdlib : malloc, free;

    this(T t)
    {
        this.val = cast(T*) malloc(T.sizeof);
        moveEmplace(t, *this.val);
        static if (hasIndirections!T)
            GC.addRange(this.val, T.sizeof);
    }

    this(Args...)(auto ref Args args)
    {
        this.val = cast(T*) malloc(T.sizeof);
        emplace(this.val, args);
        static if (hasIndirections!T)
            GC.addRange(this.val, T.sizeof);
    }

    ~this()
    {
        if (this.val !is null)
        {
            import std.traits : hasMember;
            static if (hasMember!(T, "__dtor"))
                this.val.__dtor();
            GC.removeRange(this.val);
            free(this.val);
            destroy(this.val);
        }
    }

    void opAssign(T)(T o)
    {
        destroy(this);
        this.val = cast(T*) malloc(T.sizeof);
        moveEmplace(o, *this.val);
        static if (hasIndirections!T)
            GC.addRange(this.val, T.sizeof);
    }

    void opAssign(Own!T o)
    {
        destroy(this);
        this.val = o.val;
        o.val = null;
    }
    
    @property bool isNull() const
    {
        return this.val is null; 
    }

    mixin Proxy!val;

private:
    T* val;
    @disable this(this);
}

unittest
{
    import std.algorithm : move;
    struct X
    {
        bool b;
    }

    Own!X x;
    x = Own!X(true);
    assert(x.b);
    Own!X y = Own!X(true); 
    x = y.move();
    assert(y.val is null);
    x.b = false;
    auto z = Own!X(*x.move());
    assert(x.isNull);
    assert(!z.b);

    Own!X w = true;
    Own!X v;

    assert(w != v);

    int i;
    struct C
    {
        this(ref int i)
        {
            ++i;
            ii = &i;
        }

        @disable this();
        @disable this(this);
        
        ~this()
        {
            --(*ii);
        }
        int* ii;
    }

    {
        Own!C dd = Own!C(i);
        auto c = dd.move();
    }
    assert(i == 0);
}