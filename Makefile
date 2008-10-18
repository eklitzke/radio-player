radio: radio.hs
	ghc --make $?

clean:
	-rm -f *.hi *.o

.PHONY: clean
