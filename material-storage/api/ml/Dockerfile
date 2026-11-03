# ms-ml 推理服务镜像(工作包 F,ai-tagging-slicing 方案 §7.1)
# 与 api/Dockerfile 彻底分离:torch 全家只进本镜像,ms-api/ms-worker/ms-ai-worker 零 ML 依赖
# torch 走 CPU 轮子(download.pytorch.org/whl/cpu,~200MB,不装 CUDA 运行时)
# stub/stub-fault 模式无需权重即可起(CI/dev 全链路);real 模式挂 /models/smolvlm2-256m 只读卷
#
# build context = api/(compose:build.context ./api + dockerfile ml/Dockerfile)
# apt / pip 源可经 build arg 覆盖(沿 api/Dockerfile 同款写法)

FROM python:3.12-slim

ARG APT_MIRROR=mirrors.tuna.tsinghua.edu.cn
ARG PIP_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple

RUN sed -i "s|deb.debian.org|${APT_MIRROR}|g" /etc/apt/sources.list.d/debian.sources \
 && pip config set global.index-url ${PIP_INDEX_URL}

ENV PYTHONUNBUFFERED=1 \
    # 默认 stub:无权重即可起,CI/dev 全链路可跑(compose 按 profile 覆盖为 real)
    MS_ML_MODE=stub

WORKDIR /app
# 先只 COPY constraints(依赖层缓存:改代码不重装 torch)
COPY ml/constraints.txt /app/ml/constraints.txt
# torch 单独一步走 pytorch CPU index(其余步骤走 PIP_INDEX_URL);
# -c 只钉版本号,CPU 轮子在该 index 提供(见 constraints.txt 头注)
RUN pip install --no-cache-dir --index-url https://download.pytorch.org/whl/cpu \
      -c ml/constraints.txt torch

# 其余依赖统一受 constraints 钉版(transformers/num2words/pillow/fastapi/uvicorn/pydantic)
RUN pip install --no-cache-dir -c ml/constraints.txt \
      transformers num2words pillow fastapi "uvicorn[standard]" pydantic

COPY ml /app/ml

# workdir=/app/ml:uvicorn 以顶层模块加载 app.py;model_runner 同目录可 import
WORKDIR /app/ml

EXPOSE 8000
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "8"]
