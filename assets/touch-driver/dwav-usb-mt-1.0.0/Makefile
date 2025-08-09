#------------------------------------------------------------------------------
#------------------------------------------------------------------------------
#
# ODROID-VIEW Series Multi-touch Device driver (Hardkernel Co.,Ltd)
#
#------------------------------------------------------------------------------
# ODROID-VIEW VID:PID List
#
# 0x0eef:0x0005		- ODROID-VU7
# 0x16b4:0x0704		- ODROID-VU5
# 0x16b4:0x0705		- ODROID-VU7 PLUS
#
#------------------------------------------------------------------------------
# Linux GRUB update for odroid view series(setup ignored usbhid device)
#
# 1. From a terminal (or after pressing Alt + F2) run:
#	gksudo gedit /etc/default/grub
# (or use sudo nano if gksudo or gedit are not available) and enter your password.
#
# 2. Find the line starting with GRUB_CMDLINE_LINUX_DEFAULT or
#    GRUB_CMDLINE_LINUX and append foo=bar to its end.
#    For example:
#	GRUB_CMDLINE_LINUX_DEFAULT="quiet splash foo=bar"
#
#	/* ODROID-VU5 ignored usbhid device setup */
#	GRUB_CMDLINE_LINUX="usbhid.quirks=0x16b4:0x0704:0x04"
#
#	/* ODROID-VIEW all series ignored usbhid device setup */
#	GRUB_CMDLINE_LINUX="usbhid.quirks=0x0eef:0x0005:0x04,0x16b4:0x0704:0x04,0x16b4:0x0705:0x04"
# Save the file and close the editor.
#
# 3. Finally, start a terminal and run:
#	sudo update-grub
# to update GRUB's configuration file (you probably need to enter your password).
#
# On the next reboot, the kernel should be started with the boot parameter.
# To permanently remove it, simply remove the parameter from GRUB_CMDLINE_LINUX_DEFAULT and
# run sudo update-grub again.
#
# To verify your changes, you can see exactly what parameters your kernel booted with
# by executing
#	cat /proc/cmdline.
#------------------------------------------------------------------------------
# usbhid quirks confirm
#	cat /sys/module/usbhid/parameters/quirks
#------------------------------------------------------------------------------
#------------------------------------------------------------------------------
KERNEL_VERSION		:= $(shell uname -r)
KERNEL_MODULE_DIR	:= /lib/modules/$(KERNEL_VERSION)
KERNEL_SOURCE		:= $(KERNEL_MODULE_DIR)/build

DRIVER_MODULE_NAME	:= dwav-usb-mt
DRIVER_INSTALL_DIR	:= $(KERNEL_MODULE_DIR)/kernel/drivers/input/touchscreen

obj-m += $(DRIVER_MODULE_NAME).o

all:
	$(MAKE) -C $(KERNEL_SOURCE) M=$(shell pwd) modules

clean:
	$(MAKE) -C $(KERNEL_SOURCE) M=$(shell pwd) clean

install:
	install -p -m 644 $(DRIVER_MODULE_NAME).ko $(DRIVER_INSTALL_DIR)
	/sbin/depmod -a $(KERNEL_VERSION)

uninstall:
	rm -f $(DRIVER_INSTALL_DIR)/$(DRIVER_MODULE_NAME).ko
	/sbin/depmod -a $(KERNEL_VERSION)
