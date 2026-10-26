cmake_minimum_required(VERSION 3.22.1)
project(usb_exclusive C)

add_library(usb_exclusive SHARED
    usb_desc.c
    usb_gain.c
    usb_exclusive.c
)

target_link_libraries(usb_exclusive log)
target_compile_options(usb_exclusive PRIVATE -Wall -Wextra -Wno-unused-parameter)
