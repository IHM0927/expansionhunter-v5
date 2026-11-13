version 1.0

workflow EHO {
    input {
        # Sample information
        File cram
        File crai
        String? name
        String sex
        String mode = "streaming"

        # References
        File ref_fasta
        File ref_fasta_index
        File variant_catalog
    }

    call EHO {
        input:
            cram = cram,
            crai = crai,
            name = select_first([name, basename(cram, ".cram")]),
            sex = sex,
            ref_fasta = ref_fasta,
            ref_fasta_index = ref_fasta_index,
            variant_catalog = variant_catalog,
            mode = mode
    }

    output {
        File json = EHO.json
        File bam = EHO.bam
        File vcf = EHO.vcf
    }
}

task EHO {
    input {
        File cram
        File crai
        String name = basename(cram, ".cram")
        String sex
        File variant_catalog
        String mode = "streaming"

        # References
        File ref_fasta
        File ref_fasta_index

        # Runtime parameters
        String docker = "hydragenetics/expansionhunter:5.0.0"
        Int cpu = 1
        Float machine_mem_gb = 1.8
    }

    command <<<
        # 실패하더라도 진단을 기록한 뒤 EH의 종료 코드를 반환
        set +e

        EH_PID=""
        CG=""

        # cgroup v2 메모리 경로 확인
        CG_REL=$(awk -F: '$1 == "0" {print $3}' /proc/self/cgroup)

        for d in "/sys/fs/cgroup$CG_REL" /sys/fs/cgroup; do
            if [ -r "$d/memory.current" ]; then
                CG="$d"
                break
            fi
        done

        # v2를 찾지 못하면 cgroup v1 확인
        if [ -z "$CG" ]; then
            CG_REL=$(awk -F: \
                '$2 ~ /(^|,)memory(,|$)/ {print $3}' \
                /proc/self/cgroup)

            for d in \
                "/sys/fs/cgroup/memory$CG_REL" \
                /sys/fs/cgroup/memory
            do
                if [ -r "$d/memory.usage_in_bytes" ]; then
                    CG="$d"
                    break
                fi
            done
        fi

        snapshot() {
            echo "[DIAG] time=$(date -u +%FT%TZ) phase=$1"

            # VM에서 보이는 전체 메모리와 사용 가능한 메모리
            awk '/^(MemTotal|MemAvailable|SwapTotal|SwapFree):/ {
                print "[DIAG] host " $0
            }' /proc/meminfo

            # EH 프로세스 메모리 사용량
            if [ -n "$EH_PID" ] && [ -r "/proc/$EH_PID/status" ]; then
                awk '/^(VmRSS|VmHWM|VmSize|Threads):/ {
                    print "[DIAG] EH " $0
                }' "/proc/$EH_PID/status"
            fi

            # cgroup 메모리 사용량, 제한, OOM 카운터
            if [ -n "$CG" ]; then
                for f in \
                    memory.current \
                    memory.peak \
                    memory.max \
                    memory.events \
                    memory.events.local \
                    memory.usage_in_bytes \
                    memory.max_usage_in_bytes \
                    memory.limit_in_bytes \
                    memory.failcnt \
                    memory.oom_control
                do
                    if [ -r "$CG/$f" ]; then
                        echo "[DIAG] cgroup_file=$CG/$f"
                        sed 's/^/[DIAG] /' "$CG/$f"
                    fi
                done
            fi
        }

        echo "[DIAG] requested_cpu=~{cpu}"
        echo "[DIAG] requested_memory_gb=~{machine_mem_gb}"
        echo "[DIAG] cgroup_path=$CG"

        if [ -z "$CG" ]; then
            echo "[DIAG] Memory cgroup counters unavailable"
        fi

        sed 's/^/[DIAG] membership /' /proc/self/cgroup
        snapshot before

        # 기존과 동일한 분석 옵션
        ExpansionHunter \
            --reads "~{cram}" \
            --reference "~{ref_fasta}" \
            --variant-catalog "~{variant_catalog}" \
            --output-prefix "~{name}.EH" \
            --sex "~{sex}" \
            --analysis-mode "~{mode}" \
            --threads ~{cpu} &

        EH_PID=$!
        echo "[DIAG] EH_PID=$EH_PID"

        # 분석 중 30초 간격으로 stdout에 기록
        (
            while kill -0 "$EH_PID" 2>/dev/null; do
                snapshot running
                sleep 30
            done
        ) &
        MONITOR_PID=$!

        # EH 종료 코드를 보존
        wait "$EH_PID"
        EH_RC=$?

        # 모니터링 종료
        kill "$MONITOR_PID" 2>/dev/null
        wait "$MONITOR_PID" 2>/dev/null

        # 종료 후 메모리 및 OOM 카운터 기록
        snapshot after
        echo "[DIAG] ExpansionHunter_exit_code=$EH_RC"

        exit "$EH_RC"
    >>>

    runtime {
        docker: docker
        memory: machine_mem_gb + " GB"
        cpu: cpu
        disks: "local-disk " + ceil(2 * size(cram, "G")) + " HDD"
    }

    output {
        File json = "~{name}.EH.json"
        File bam = "~{name}.EH_realigned.bam"
        File vcf = "~{name}.EH.vcf"
    }
}
