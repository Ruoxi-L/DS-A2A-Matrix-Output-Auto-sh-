*在真实路由布局计算之后、DeepEPdiapatch之前，增加patch文件。  
  >顶部import/全局计数器/新增trace_ep_rank()和trace_a2a_dispatch_matrix()/dispatch前调用矩阵  
    
*Watcher脚本  
  >每120s检查一次GPU（显存used<=500MB、GPU利用率、是否有compute process）  
  >第一次发现空8卡，做6次稳定性检查，每次间隔10s  
  >稳定通过后，自动启动vLLM容器  
  >等待vLLM API ready，自动发送512次请求，16并发  
  >...

*一些其他脚本  
 >00_check_vllm_flags.sh：确认参数存在
 >01_start_vllm_with_trace.sh：启动推理容器，挂载模型、挂载patch，用patch覆盖容器中deepep_ht.py
 >02_send_test_request.sh：向vLLM API发送多Prompt请求，产生真实推理负载
 >03_collect_a2a_matrix.py：读取数据，汇总生成token matrix/byte matrix/event imbalance和summary.json
