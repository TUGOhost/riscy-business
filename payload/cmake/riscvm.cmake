set(EMBED_TYPE "post-merge-pre-opt") # post-merge-pre-opt/optimized
if(NOT CMAKE_CXX_COMPILER_ID MATCHES "Clang")
    message(FATAL_ERROR "clang-cl is required, use -T ClangCL --fresh")
elseif(CMAKE_CXX_COMPILER_FRONTEND_VARIANT MATCHES "^MSVC$")
    # clang-cl
    add_compile_options(-flto)
    add_link_options(/mllvm:-lto-embed-bitcode=${EMBED_TYPE})
else()
    # clang
    add_compile_options(-fuse-ld=lld-link -flto)
    add_link_options(-Wl,/mllvm:-lto-embed-bitcode=${EMBED_TYPE})
    # NOTE: none of these are working
    #add_link_options(-mllvm -lto-embed-bitcode=${EMBED_TYPE})
    #add_link_options(--plugin-opt=-lto-embed-bitcode=${EMBED_TYPE})
    #add_compile_options(-Wl,-mllvm,-lto-embed-bitcode=${EMBED_TYPE})
    #add_compile_options(-Wl,--plugin-opt=-lto-embed-bitcode=${EMBED_TYPE})
endif()

# Some common annoying warnings when including Windows.h
add_compile_options(-Wno-pragma-pack -Wno-microsoft-enum-forward-reference)

# Find the regular LLVM toolchain
get_filename_component(LLVM_DIR "${CMAKE_CXX_COMPILER}" DIRECTORY)
find_program(CLANG_EXECUTABLE clang.exe PATHS "${LLVM_DIR}" NO_DEFAULT_PATH REQUIRED)
message(STATUS "Found clang: ${CLANG_EXECUTABLE}")
find_program(LLD_EXECUTABLE ld.lld.exe PATHS "${LLVM_DIR}" NO_DEFAULT_PATH REQUIRED)
message(STATUS "Found lld: ${LLD_EXECUTABLE}")
find_program(OBJCOPY_EXECUTABLE llvm-objcopy.exe PATHS "${LLVM_DIR}" NO_DEFAULT_PATH REQUIRED)
message(STATUS "Found llvm-objcopy: ${OBJCOPY_EXECUTABLE}")

set(RISCVM_DIR "${CMAKE_CURRENT_LIST_DIR}/../../riscvm" CACHE PATH "Path to the riscvm directory")

message(STATUS "Compiling RV64 CRT...")
set(CRT0_SRC "${RISCVM_DIR}/lib/crt0.c")
set(CRT0_OBJ "${CMAKE_CURRENT_BINARY_DIR}/crt0.o")
configure_file("${CRT0_SRC}" crt0.c COPYONLY)
set(RV64_FLAGS -target riscv64 -march=rv64im -mcmodel=medany -fno-exceptions -fshort-wchar -Os)
execute_process(
    COMMAND "${CLANG_EXECUTABLE}" -x c ${RV64_FLAGS} -c "${CRT0_SRC}" -o "${CRT0_OBJ}"
    ECHO_OUTPUT_VARIABLE
    ECHO_ERROR_VARIABLE
    COMMAND_ERROR_IS_FATAL ANY
)

# TODO: download the transpiler
set(TRANSPILER "${RISCVM_DIR}/../transpiler/build/RelWithDebInfo/transpiler.exe" CACHE FILEPATH "Path to the transpiler binary")

# TODO: only create venv if it doesn't exist

# Find system python
find_package(Python3 COMPONENTS Interpreter REQUIRED)
message(STATUS "Creating venv...")
set(VENV_DIR "${CMAKE_CURRENT_BINARY_DIR}/venv")
execute_process(
    COMMAND "${Python3_EXECUTABLE}" -m venv "${VENV_DIR}"
    ECHO_OUTPUT_VARIABLE
    ECHO_ERROR_VARIABLE
    COMMAND_ERROR_IS_FATAL ANY
)

# Switch to venv (https://discourse.cmake.org/t/possible-to-create-a-python-virtual-env-from-cmake-and-then-find-it-with-findpython3/1132/2)
set(ENV{VIRTUAL_ENV} "${VENV_DIR}")
set(Python3_FIND_VIRTUALENV FIRST)
unset(Python3_EXECUTABLE)
find_package(Python3 COMPONENTS Interpreter REQUIRED)

message(STATUS "Installing dependencies...")
execute_process(
    COMMAND "${Python3_EXECUTABLE}" -m pip install -r "${RISCVM_DIR}/requirements.txt" --disable-pip-version-check
    ECHO_OUTPUT_VARIABLE
    ECHO_ERROR_VARIABLE
    COMMAND_ERROR_IS_FATAL ANY
)

function(add_riscvm_executable tgt)
    add_executable(${tgt} ${ARGN})
    if(MSVC)
        target_compile_definitions(${tgt} PRIVATE _NO_CRT_STDIO_INLINE)
        target_compile_options(${tgt} PRIVATE /GS- /Zc:threadSafeInit-)
    endif()
    set(BC_BASE "$<TARGET_FILE_DIR:${tgt}>/$<TARGET_FILE_BASE_NAME:${tgt}>")
    add_custom_command(TARGET ${tgt}
        POST_BUILD
        USES_TERMINAL
        COMMENT "Extracting and transpiling bitcode..."
        COMMAND "${Python3_EXECUTABLE}" "${RISCVM_DIR}/extract-bc.py" "$<TARGET_FILE:${tgt}>" -o "${BC_BASE}.bc" --importmap "${BC_BASE}.imports"
        COMMAND "${TRANSPILER}" -input "${BC_BASE}.bc" -importmap "${BC_BASE}.imports" -output "${BC_BASE}.rv64.bc"
        COMMAND "${CLANG_EXECUTABLE}" ${RV64_FLAGS} -c "${BC_BASE}.rv64.bc" -o "${BC_BASE}.rv64.o"
        COMMAND "${LLD_EXECUTABLE}" -o "${BC_BASE}.elf" --oformat=elf -emit-relocs -T "${RISCVM_DIR}/lib/linker.ld" "--Map=${BC_BASE}.map" "${CRT0_OBJ}" "${BC_BASE}.rv64.o"
        COMMAND "${OBJCOPY_EXECUTABLE}" -O binary "${BC_BASE}.elf" "${BC_BASE}.pre.bin"
        COMMAND "${Python3_EXECUTABLE}" "${RISCVM_DIR}/relocs.py" "${BC_BASE}.elf" --binary "${BC_BASE}.pre.bin" --output "${BC_BASE}.bin"
        COMMAND "${Python3_EXECUTABLE}" "${RISCVM_DIR}/encrypt.py" --encrypt --shuffle --map "${BC_BASE}.map" --shuffle-map "${RISCVM_DIR}/shuffled_opcodes.json" --opcodes-map "${RISCVM_DIR}/opcodes.json" --output "${BC_BASE}.enc.bin" "${BC_BASE}.bin"
        VERBATIM
    )
endfunction()
