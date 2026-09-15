mulrowlo:   .repeat RINGROWS+1, i
            .byte <(i*ROWCHARS)
            .endrepeat
mulrowhi:   .repeat RINGROWS+1, i
            .byte >(i*ROWCHARS)
            .endrepeat
