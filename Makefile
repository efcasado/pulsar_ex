.PHONE: all deps compile clean shell

SHELL := BASH_ENV=.rc /bin/bash --noprofile


## Targets
##=========================≈===============================================

all: deps compile

deps:
	mix deps.get

compile:
	mix compile

shell:
	iex -S mix

clean:
	mix clean
