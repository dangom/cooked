"""A program that reads a line in raw mode, the way an agent's chat does.

For cooked-tests-program-line.el.  It echoes what it is typed, takes bracketed
pastes, rubs out on Backspace, and reports the line on Enter.  `?' typed into an
empty line opens a menu instead: `1' and `2' answer it and everything else -- a
paste included -- is ignored, which is what makes it a menu.  Escape is
reported, and C-a takes the alternate screen.  Like an agent, it draws a cursor
of its own after the line, so its row goes on past where it reads.
"""

import os
import sys
import tty

tty.setraw(0)
out = sys.stdout


def write(text):
    out.write(text)
    out.flush()


write('\x1b[?2004h')
for i in range(1, 61):
    write('line %d\r\n' % i)

line = ''
menu = False


def prompt():
    # A cursor of its own after the line, drawn in reverse video with the real
    # one stepped back onto it -- as an agent with its own cursor does.
    write('\r\x1b[K> ' + line.replace('\n', '|') + '\x1b[7m \x1b[0m\x1b[D')


def report(text):
    write('\r\x1b[K' + text + '\r\n')
    prompt()


prompt()
pending = b''
while True:
    data = os.read(0, 4096)
    if not data:
        break
    pending += data
    while pending:
        if pending.startswith(b'\x1b[200~'):
            end = pending.find(b'\x1b[201~')
            if end < 0:
                break
            text = pending[6:end].decode()
            pending = pending[end + 6:]
            if not menu:
                line += text.replace('\r', '\n')
                prompt()
            continue
        if pending.startswith(b'\x1b['):
            i = 2
            while i < len(pending) and not 0x40 <= pending[i] <= 0x7e:
                i += 1
            pending = pending[i + 1:]
            continue
        byte, pending = pending[:1], pending[1:]
        if byte == b'\x1b':
            report('got escape')
        elif byte == b'\x01':
            write('\x1b[?1049h\x1b[Halt screen')
        elif menu:
            if byte in (b'1', b'2'):
                menu = False
                report('chose ' + byte.decode())
        elif byte == b'\r':
            sent, line = line, ''
            report('sent: ' + repr(sent))
        elif byte == b'\x7f':
            line = line[:-1]
            prompt()
        elif byte == b'?' and not line:
            menu = True
            write('\r\x1b[K? 1. yes  2. no\r\x1b[2C')
        elif byte >= b' ':
            line += byte.decode('latin-1')
            prompt()
