obj-m += mma8451q.o

KDIR ?= /lib/modules/$(shell uname -r)/build
PWD := $(shell pwd)

ccflags-y := -I$(PWD) -Wno-unused-function -Wno-implicit-function-declaration

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean

install: all
	install -m 644 mma8451q.ko /lib/modules/$(shell uname -r)/extra/
	depmod -a

.PHONY: all clean install
