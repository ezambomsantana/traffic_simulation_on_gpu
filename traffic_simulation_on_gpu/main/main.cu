/**
 *This project targets to check GPU is an option for DynaMIT.
 *This project also targets for a paper "Mesoscopic Traffic Simulation on GPU"
 */

#include <cuda.h>
#include <cuda_runtime.h>
#include <cuda_runtime_api.h>
#include "../on_cpu/network/Network.h"
#include "../on_cpu/demand/OD_Pair.h"
#include "../on_cpu/demand/OD_Path.h"
#include "../on_cpu/demand/Vehicle.h"
#include "../on_cpu/util/TimeTools.h"

#include "../on_cpu/util/shared_cpu_include.h"
#include "../on_gpu/supply/kernel_functions.h"
#include "../on_gpu/supply/OnGPUMemory.h"
#include "../on_cpu/util/SimulationResults.h"
#include "../on_gpu/supply/OnGPUVehicle.h"
#include "../on_gpu/supply/OnGPUNewLaneVehicles.h"

using namespace std;

/**
 * CUDA Execution Configuration
 */
int roadBlocks;
int roadThreadsInABlock;

int nodeBlocks;
int nodeThreadsInABlock;

/*
 * Demand
 */
Network* the_network;
vector<OD_Pair*> all_od_pairs;
vector<OD_Pair_PATH*> all_od_paths;
vector<Vehicle*> all_vehicles;

/*
 * Path Input Config
 */
std::string network_file_path = "data/network_10.dat";
std::string demand_file_path = "data/demand_10.dat";
std::string od_pair_file_path = "data/od_pair_10.dat";
std::string od_pair_paths_file_path = "data/od_pair_paths_10.dat";

/*
 * All data in GPU
 */
GPUMemory* gpu_data;

/**
 * Simulation Results
 */
std::string simulation_output_file_path = "output/simulated_outputs.txt";
std::map<int, SimulationResults*> simulation_results_pool;
ofstream simulation_results_output_file;

/*
 * GPU Streams
 * stream1: GPU Supply Simulation
 */
cudaStream_t stream_gpu_supply;
cudaEvent_t GPU_supply_one_time_simulation_done_event;

/*
 * Time Management
 */
long simulation_start_time;
long simulation_end_time;
long simulation_time_step;

/*
 * simulation_time is already finished time;
 * simulation_time + 1 might be the current simulating time on GPU
 */
long to_simulate_time;

/*
 * simulation_results_outputed_time is already outputted time;
 * simulation_results_outputed_time + 1 might be the outputing time on CPU
 */
long to_output_simulation_result_time;

/*
 * Define Major Functions
 */
bool load_in_network();
bool load_in_demand();
bool initilizeCPU();
bool initilizeGPU();
bool initGPUData(GPUMemory* data_local);

bool start_simulation();
bool destory_resources();

/*
 * Define Helper Functions
 */
bool copy_simulated_results_to_CPU(int time_step);
bool output_simulated_results(int time_step);

inline int timestep_to_arrayindex(int time_step) {
	return (time_step - START_TIME_STEPS) / UNIT_TIME_STEPS;
}

/*
 * Supply Function Define
 */
__global__ void supply_simulation_pre_vehicle_passing(GPUMemory* gpu_data, int time_step, int segment_length);
__global__ void supply_simulation_vehicle_passing(GPUMemory* gpu_data, int time_step, int node_length);
__global__ void supply_simulation_after_vehicle_passing(GPUMemory* gpu_data, int time_step, int segment_length);

__device__ GPUVehicle* get_next_vehicle_at_node(GPUMemory* gpu_data, int node_id, int* lane_id);

/*
 * MAIN
 */
int main() {
	if (load_in_network() == false) {
		cout << "Loading network fails" << endl;
		return 0;
	}

	if (load_in_demand() == false) {
		cout << "Loading demand fails" << endl;
		return 0;
	}

	if (initilizeCPU() == false) {
		cout << "InitilizeCPU fails" << endl;
		return 0;
	}

	if (initilizeGPU() == false) {
		cout << "InitilizeGPU fails" << endl;
		return 0;
	}

	//create streams
	cudaStreamCreate(&stream_gpu_supply);
	//create a event
	cudaEventCreate(&GPU_supply_one_time_simulation_done_event);

	TimeTools profile;
	profile.start_profiling();

	//Start Simulation
	if (start_simulation() == false) {
		cout << "Simulation fails" << endl;
		destory_resources();
		return 0;
	}

	profile.end_profiling();
	profile.output();

	cout << "Simulation Succeed!" << endl;

	destory_resources();
	return 0;
}

/**
 *
 */
bool load_in_network() {
	the_network = new Network();

	the_network->all_links.clear();
	the_network->all_nodes.clear();
	the_network->node_mapping.clear();

	return Network::load_network(the_network, network_file_path);
}

bool load_in_demand() {

	if (OD_Pair::load_in_all_ODs(all_od_pairs, od_pair_file_path) == false) {
		return false;
	}

	if (OD_Pair_PATH::load_in_all_OD_Paths(all_od_paths, od_pair_paths_file_path) == false) {
		return false;
	}

	if (Vehicle::load_in_all_vehicles(all_vehicles, demand_file_path) == false) {
		return false;
	}

	return true;
}

bool initilizeCPU() {
	simulation_start_time = START_TIME_STEPS;
	simulation_end_time = END_TIME_STEPS; // 2 hours
	simulation_time_step = UNIT_TIME_STEPS;

	assert(simulation_time_step == 1);

	to_simulate_time = simulation_start_time;
	to_output_simulation_result_time = simulation_start_time;

	roadThreadsInABlock = 32;
	nodeThreadsInABlock = 32;

	roadBlocks = LANE_SIZE / roadThreadsInABlock + 1;
	nodeBlocks = NODE_SIZE / nodeThreadsInABlock + 1;

	simulation_results_pool.clear();
	simulation_results_output_file.open(simulation_output_file_path.c_str());
	simulation_results_output_file << "##TIME STEP" << ":Lane ID:" << ":(" << "COUNTS" << ":" << "flow" << ":" << "density" << ":" << "speed" << ":" << "queue_length" << ")" << endl;

	return true;
}

__global__ void linkGPUData(GPUMemory *gpu_data, GPUVehicle *vpool){
	int idx = threadIdx.x * blockIdx.x * blockDim.x;
	int nVehiclePerTick = VEHICLE_MAX_LOADING_ONE_TIME * LANE_SIZE;
	GPUVehicle ***v = (GPUVehicle***)gpu_data->new_vehicles_every_time_step->new_vehicles;
}

GPUVehicle *vpool_h;
size_t vpool_size = VEHICLE_MAX_LOADING_ONE_TIME * LANE_SIZE * TOTAL_TIME_STEPS * sizeof(GPUVehicle);
bool initilizeGPU() {
	gpu_data = NULL;

	GPUMemory* data_local = new GPUMemory();
	initGPUData(data_local);
	GPUVehicle *vpool;
	printf("vpool size: %d", sizeof(GPUVehicle) * VEHICLE_MAX_LOADING_ONE_TIME * LANE_SIZE * TOTAL_TIME_STEPS);
	cudaMalloc((void**)&vpool,
		sizeof(GPUVehicle) * VEHICLE_MAX_LOADING_ONE_TIME * LANE_SIZE * TOTAL_TIME_STEPS);

//	data_local->test = 1;

	if (cudaMalloc(&gpu_data, data_local->total_size()) != cudaSuccess) {
		cerr << "cudaMalloc(&gpu_data, sizeof(GPUMemory)) failed" << endl;
	}

	/*
	 * Hi, Xiaosong, the copy fucntion needs to be changed.
	 */
	cudaMemcpy(gpu_data, data_local, data_local->total_size(), cudaMemcpyHostToDevice);

	// copy vpool_h to vpool, to be linked with gpu_data later. /*xiaosong*/
	cudaMemcpy(vpool, vpool_h, vpool_size, cudaMemcpyDeviceToHost);

	int BLOCK_SIZE = 256;
	int GRID_SIZE = TOTAL_TIME_STEPS;
	linkGPUData<<<BLOCK_SIZE, GRID_SIZE>>>(gpu_data, vpool);
	return true;
}

/*
 * Build a GPU data
 */
bool initGPUData(GPUMemory* data_local) {

	/**
	 * First Part: Lane
	 */

	for (int i = 0; i < the_network->all_links.size(); i++) {
		Link* one_link = the_network->all_links[i];

		data_local->lane_pool.lane_ID[i] = one_link->link_id;
		//make sure assert is working
//		assert(1 == 0);

		assert(one_link->link_id == i);

		data_local->lane_pool.from_node_id[i] = one_link->from_node->node_id;
		data_local->lane_pool.to_node_id[i] = one_link->to_node->node_id;

		data_local->lane_pool.Tp[i] = simulation_start_time - simulation_time_step;
		data_local->lane_pool.Tq[i] = simulation_start_time - simulation_time_step;
		data_local->lane_pool.accumulated_offset[i] = 0;

		data_local->lane_pool.flow[i] = 0;
		data_local->lane_pool.density[i] = 0;
		data_local->lane_pool.speed[i] = 0;
		data_local->lane_pool.queue_length[i] = 0;

		/*
		 * for density calculation
		 */
		data_local->lane_pool.lane_length[i] = ROAD_LENGTH; // meter
		data_local->lane_pool.max_vehicles[i] = ROAD_LENGTH / VEHICLE_LENGTH; //number of vehicles
		data_local->lane_pool.output_capacity[i] = LANE_OUTPUT_CAPACITY_TIME_STEP; //
		data_local->lane_pool.input_capacity[i] = LANE_INPUT_CAPACITY_TIME_STEP; //
		data_local->lane_pool.empty_space[i] = ROAD_LENGTH;

		/*
		 * for speed calculation
		 */
		data_local->lane_pool.alpha[i] = Alpha;
		data_local->lane_pool.beta[i] = Beta;
		data_local->lane_pool.max_density[i] = Max_Density;
		data_local->lane_pool.min_density[i] = Min_Density;
		data_local->lane_pool.MAX_SPEED[i] = MAX_SPEED;
		data_local->lane_pool.MIN_SPEED[i] = MIN_SPEED;

		data_local->lane_pool.vehicle_counts[i] = 0;
		data_local->lane_pool.vehicle_passed_to_the_lane_counts[i] = 0;

		for (int c = 0; c < MAX_VEHICLE_PER_LANE; c++) {
			data_local->lane_pool.vehicle_passed_space[c][i] = NULL;
		}

		for (int c = 0; c < LANE_INPUT_CAPACITY_TIME_STEP; c++) {
			data_local->lane_pool.vehicle_passed_space[c][i] = NULL;
		}

		for (int j = 0; j < TOTAL_TIME_STEPS; j++) {
			data_local->lane_pool.speed_history[j][i] = -1;
		}

		//it is assumed that QUEUE_LENGTH_HISTORY = 4;
		assert(QUEUE_LENGTH_HISTORY == 4);
		float weight[QUEUE_LENGTH_HISTORY];
		weight[0] = 0.5;
		weight[1] = 0.3;
		weight[2] = 0.2;
		weight[3] = 0;

		//		{ 0.2, 0.3, 0.5, 0 };

		for (int j = 0; j < QUEUE_LENGTH_HISTORY; j++) {
			data_local->lane_pool.his_queue_length[j][i] = -1;
			data_local->lane_pool.his_queue_length_weighting[j][i] = weight[j];
		}

		data_local->lane_pool.predicted_empty_space[i] = 0;
		data_local->lane_pool.predicted_queue_length[i] = 0;
	}

	/**
	 * Second Part: Node
	 */
	//	NodePool* the_node_pool = data_local->node_pool;
	for (int i = 0; i < the_network->all_nodes.size(); i++) {
		Node* one_node = the_network->all_nodes[i];

		data_local->node_pool.node_ID[i] = one_node->node_id;
		data_local->node_pool.MAXIMUM_ACCUMULATED_FLOW[i] = 0;
		data_local->node_pool.ACCUMULATYED_UPSTREAM_CAPACITY[i] = 0;
		data_local->node_pool.ACCUMULATYED_DOWNSTREAM_CAPACITY[i] = 0;

		assert(one_node->node_id == i);

		for (int j = 0; j < MAX_LANE_UPSTREAM; j++) {
			data_local->node_pool.upstream[j][i] = -1;
		}

		for (int j = 0; j < one_node->upstream_links.size(); j++) {
			data_local->node_pool.upstream[j][i] = one_node->upstream_links[j]->link_id;
			data_local->node_pool.ACCUMULATYED_UPSTREAM_CAPACITY[i] += LANE_OUTPUT_CAPACITY_TIME_STEP;
		}

		for (int j = 0; j < MAX_LANE_DOWNSTREAM; j++) {
			data_local->node_pool.downstream[j][i] = -1;
		}

		for (int j = 0; j < one_node->downstream_links.size(); j++) {
			data_local->node_pool.downstream[j][i] = one_node->downstream_links[j]->link_id;
			data_local->node_pool.ACCUMULATYED_DOWNSTREAM_CAPACITY[i] += LANE_OUTPUT_CAPACITY_TIME_STEP;
		}

		data_local->node_pool.MAXIMUM_ACCUMULATED_FLOW[i] =
				(data_local->node_pool.ACCUMULATYED_UPSTREAM_CAPACITY[i] < data_local->node_pool.ACCUMULATYED_DOWNSTREAM_CAPACITY[i]) ?
						data_local->node_pool.ACCUMULATYED_UPSTREAM_CAPACITY[i] : data_local->node_pool.ACCUMULATYED_DOWNSTREAM_CAPACITY[i];

//		std::cout << "MAXIMUM_ACCUMULATED_FLOW:" << i << ", " << data_local->node_pool.MAXIMUM_ACCUMULATED_FLOW[i] << std::endl;
	}

	/**
	 * Third Part:
	 */

	//Init VehiclePool
	for (int i = 0; i < TOTAL_TIME_STEPS; i++) {
		for (int j = 0; j < LANE_SIZE; j++) {
			data_local->new_vehicles_every_time_step[i].new_vehicle_size[j] = 0;
			data_local->new_vehicles_every_time_step[i].lane_ID[j] = -1;
		}
	}

	std::cout << "all_vehicles.size():" << all_vehicles.size() << std::endl;

	//init host vehicle pool data /*xiaosong*/
	vpool_h = (GPUVehicle*)malloc(sizeof(GPUVehicle) * VEHICLE_MAX_LOADING_ONE_TIME * LANE_SIZE * TOTAL_TIME_STEPS);
	int nVehiclePerTick = VEHICLE_MAX_LOADING_ONE_TIME * LANE_SIZE;

	//Insert Vehicles
	for (int i = 0; i < all_vehicles.size(); i++) {
		Vehicle* one_vehicle = all_vehicles[i];
//		assert(one_vehicle->vehicle_id == i);

		int time_index = one_vehicle->entry_time;
		int time_index_covert = timestep_to_arrayindex(time_index);

		assert(time_index == time_index_covert);

		int lane_ID = all_od_paths[one_vehicle->path_id]->link_ids[0];

		//try to load vehicles beyond the simulation border
		if (time_index_covert >= TOTAL_TIME_STEPS) continue;

		if (data_local->new_vehicles_every_time_step[time_index_covert]->new_vehicle_size[lane_ID] < VEHICLE_MAX_LOADING_ONE_TIME) {
			int index = data_local->new_vehicles_every_time_step[time_index_covert]->new_vehicle_size[lane_ID];
			int idx_vpool = time_index_covert * nVehiclePerTick;
			idx_vpool += index * VEHICLE_MAX_LOADING_ONE_TIME;
			idx_vpool += lane_ID;

			vpool_h[idx_vpool].vehicle_ID = one_vehicle->vehicle_id;
			vpool_h[idx_vpool].entry_time = time_index;
			vpool_h[idx_vpool].current_lane_ID = lane_ID;
			int max_copy_length =
				MAX_ROUTE_LENGTH > all_od_paths[one_vehicle->path_id]->link_ids.size() ?
				all_od_paths[one_vehicle->path_id]->link_ids.size() :
				MAX_ROUTE_LENGTH;

			for (int p = 1; p < max_copy_length; p++) {
				vpool_h[idx_vpool].path_code[p - 1] = all_od_paths[one_vehicle->path_id]->route_code[p] ? 1 : 0;
			}

			//ready for the next lane, so next_path_index is set to 1, if the next_path_index == whole_path_length, it means cannot find path any more, can exit;
			vpool_h[idx_vpool].next_path_index = 1;
			vpool_h[idx_vpool].whole_path_length = all_od_paths[one_vehicle->path_id]->link_ids.size();

			data_local->new_vehicles_every_time_step[time_index_covert]->new_vehicle_size[lane_ID]++;
		}
		else {
			std::cout << "Loading Vehicles Exceeds The Loading Capacity: Time:" << time_index_covert << ", Lane_ID:" << lane_ID << std::endl;
		}
	}

	//test
//	for (int i = 0; i < TOTAL_TIME_STEPS; i++) {
//		int new_size = 0;
//
//		for (int j = 0; j < LANE_SIZE; j++) {
//			new_size += data_local->new_vehicles_every_time_step[i]->new_vehicle_size[j];
//		}
//
//		std::cout << "new_size: AT " << i << ", " << new_size << std::endl;
//	}

//	data_local->test = 126;

	return true;
}

bool destory_resources() {
	simulation_results_output_file.flush();
	simulation_results_output_file.close();

	cudaEventDestroy(GPU_supply_one_time_simulation_done_event);
	cudaStreamDestroy(stream_gpu_supply);
	return true;
}

bool start_simulation() {
	bool first_time_step = true;

	/*
	 * Simulation Loop
	 */

	while (((to_simulate_time >= simulation_end_time) && (to_output_simulation_result_time >= simulation_end_time)) == false) {

		//GPU has done simulation at current time
		if (to_simulate_time < simulation_end_time && (cudaEventQuery(GPU_supply_one_time_simulation_done_event) == cudaSuccess)) {
			//step 1
			if (first_time_step == true) {
				first_time_step = false;
			}
			else {
				copy_simulated_results_to_CPU(to_simulate_time);
				to_simulate_time += simulation_time_step;
			}

			//step 2
			cout << "to_simulate_time:" << to_simulate_time << ", simulation_end_time:" << simulation_end_time << endl;

			//setp 3
			supply_simulation_pre_vehicle_passing<<<roadBlocks, roadThreadsInABlock, 0, stream_gpu_supply>>>(gpu_data, to_simulate_time, LANE_SIZE);
			supply_simulation_vehicle_passing<<<nodeBlocks, nodeThreadsInABlock, 0, stream_gpu_supply>>>(gpu_data, to_simulate_time, NODE_SIZE);
			supply_simulation_after_vehicle_passing<<<roadBlocks, roadThreadsInABlock, 0, stream_gpu_supply>>>(gpu_data, to_simulate_time, LANE_SIZE);

			cudaEventRecord(GPU_supply_one_time_simulation_done_event, stream_gpu_supply);
		}
		//GPU is busy, so CPU does something else (I/O)
		else if (to_output_simulation_result_time < to_simulate_time) {
			output_simulated_results(to_output_simulation_result_time);
			to_output_simulation_result_time += simulation_time_step;
		}
		else {
			cout << "---------------------" << endl;
			cout << "CPU nothing to do" << endl;
			cout << "to_simulate_time:" << to_simulate_time << endl;
			cout << "to_output_simulation_result_time:" << to_output_simulation_result_time << endl;
			cout << "---------------------" << endl;
		}
	}

	return true;
}

/**
 * Minor Functions
 */
bool copy_simulated_results_to_CPU(int time_step) {
	int index = timestep_to_arrayindex(time_step);
	SimulationResults* one = new SimulationResults();

	cudaMemcpy(one->flow, gpu_data->lane_pool.flow, sizeof(float) * LANE_SIZE, cudaMemcpyDeviceToHost);
	cudaMemcpy(one->density, gpu_data->lane_pool.density, sizeof(float) * LANE_SIZE, cudaMemcpyDeviceToHost);
	cudaMemcpy(one->speed, gpu_data->lane_pool.speed, sizeof(float) * LANE_SIZE, cudaMemcpyDeviceToHost);
	cudaMemcpy(one->queue_length, gpu_data->lane_pool.queue_length, sizeof(float) * LANE_SIZE, cudaMemcpyDeviceToHost);
	cudaMemcpy(one->counts, gpu_data->lane_pool.vehicle_counts, sizeof(int) * LANE_SIZE, cudaMemcpyDeviceToHost);

	simulation_results_pool[index] = one;
	return true;
}

bool output_simulated_results(int time_step) {
	if (simulation_results_pool.find(time_step) == simulation_results_pool.end()) {
		std::cerr << "System Error, Try to output time " << time_step << ", while it is not ready!" << std::endl;
		return false;
	}

	int index = timestep_to_arrayindex(time_step);
	SimulationResults* one = simulation_results_pool[index];
	assert(one != NULL);

	for (int i = 0; i < LANE_SIZE; i++) {
		simulation_results_output_file << time_step << ":lane:" << i << ":(" << one->counts[i] << ":" << one->flow[i] << ":" << one->density[i] << ":" << one->speed[i] << ":" << one->queue_length[i]
				<< ")" << endl;
	}

//	temply not deleted
//	if(one != NULL)
//		delete one;

	return true;
}

/**
 * Kernel Functions, not sure how to move to other folder
 */

/*
 * Supply Function Implementation
 */
__global__ void supply_simulation_pre_vehicle_passing(GPUMemory* gpu_data, int time_step, int segment_length) {
	int lane_id = blockIdx.x * blockDim.x + threadIdx.x;
	if (lane_id >= segment_length) return;

	int time_index = time_step;

	gpu_data->lane_pool.new_vehicle_join_counts[lane_id] = 0;

	//init capacity
	gpu_data->lane_pool.input_capacity[lane_id] = LANE_INPUT_CAPACITY_TIME_STEP;
	gpu_data->lane_pool.output_capacity[lane_id] = LANE_OUTPUT_CAPACITY_TIME_STEP;

	//init for next GPU kernel function
	gpu_data->lane_pool.blocked[lane_id] = false;

	//load passed vehicles to the back of the lane
	for (int i = 0; i < gpu_data->lane_pool.vehicle_passed_to_the_lane_counts[lane_id]; i++) {
		if (gpu_data->lane_pool.vehicle_counts[lane_id] < gpu_data->lane_pool.max_vehicles[lane_id]) {
			gpu_data->lane_pool.vehicle_space[gpu_data->lane_pool.vehicle_counts[lane_id]][lane_id] = gpu_data->lane_pool.vehicle_passed_space[i][lane_id];
			gpu_data->lane_pool.vehicle_counts[lane_id]++;

			gpu_data->lane_pool.new_vehicle_join_counts[lane_id]++;
		}
	}
	gpu_data->lane_pool.vehicle_passed_to_the_lane_counts[lane_id] = 0;

	//
	//load newly generated vehicles to the back of the lane
	for (int i = 0; i < gpu_data->new_vehicles_every_time_step[time_index]->new_vehicle_size[lane_id]; i++) {
		if (gpu_data->lane_pool.vehicle_counts[lane_id] < gpu_data->lane_pool.max_vehicles[lane_id]) {
			gpu_data->lane_pool.vehicle_space[gpu_data->lane_pool.vehicle_counts[lane_id]][lane_id] = &(gpu_data->new_vehicles_every_time_step[time_index]->new_vehicles[i][lane_id]);
			gpu_data->lane_pool.vehicle_counts[lane_id]++;

			gpu_data->lane_pool.new_vehicle_join_counts[lane_id]++;
		}
	}

	//update speed and density
	gpu_data->lane_pool.density[lane_id] = 1.0 * VEHICLE_LENGTH * gpu_data->lane_pool.vehicle_counts[lane_id] / gpu_data->lane_pool.lane_length[lane_id];

	//Speed-Density Relationship
	gpu_data->lane_pool.speed[lane_id] = gpu_data->lane_pool.MAX_SPEED[lane_id]
			* (pow((1 - pow((gpu_data->lane_pool.density[lane_id] / gpu_data->lane_pool.max_density[lane_id]), gpu_data->lane_pool.beta[lane_id])), gpu_data->lane_pool.alpha[lane_id]));

	if (gpu_data->lane_pool.speed[lane_id] < gpu_data->lane_pool.MIN_SPEED[lane_id]) gpu_data->lane_pool.speed[lane_id] = gpu_data->lane_pool.MIN_SPEED[lane_id];

	//update speed history
	gpu_data->lane_pool.speed_history[time_index][lane_id] = gpu_data->lane_pool.speed[lane_id];

	//estimated empty_space
	if (time_step < START_TIME_STEPS + 4 * UNIT_TIME_STEPS) {
//		gpu_data->lane_pool.predicted_empty_space[lane_id] = gpu_data->lane_pool.his_queue_length[0][lane_id];
		gpu_data->lane_pool.predicted_queue_length[lane_id] = 0;
		gpu_data->lane_pool.predicted_empty_space[lane_id] = ROAD_LENGTH;
	}
	else {
		gpu_data->lane_pool.predicted_queue_length[lane_id] = gpu_data->lane_pool.his_queue_length[0][lane_id];
		gpu_data->lane_pool.predicted_queue_length[lane_id] += (gpu_data->lane_pool.his_queue_length[0][lane_id] - gpu_data->lane_pool.his_queue_length[1][lane_id])
				* gpu_data->lane_pool.his_queue_length_weighting[0][lane_id];

		gpu_data->lane_pool.predicted_queue_length[lane_id] += (gpu_data->lane_pool.his_queue_length[1][lane_id] - gpu_data->lane_pool.his_queue_length[2][lane_id])
				* gpu_data->lane_pool.his_queue_length_weighting[1][lane_id];

		gpu_data->lane_pool.predicted_queue_length[lane_id] += (gpu_data->lane_pool.his_queue_length[2][lane_id] - gpu_data->lane_pool.his_queue_length[3][lane_id])
				* gpu_data->lane_pool.his_queue_length_weighting[2][lane_id];

		//need improve
		//XUYAN, need modify
		gpu_data->lane_pool.predicted_empty_space[lane_id] = (ROAD_LENGTH - gpu_data->lane_pool.predicted_queue_length[lane_id]);
	}

	//update Tp
	gpu_data->lane_pool.accumulated_offset[lane_id] += gpu_data->lane_pool.speed[lane_id] * UNIT_TIME_STEPS; //meter

	while (gpu_data->lane_pool.accumulated_offset[lane_id] >= gpu_data->lane_pool.lane_length[lane_id]) {
		gpu_data->lane_pool.accumulated_offset[lane_id] -= gpu_data->lane_pool.speed_history[gpu_data->lane_pool.Tp[lane_id]][lane_id] * UNIT_TIME_STEPS;
		gpu_data->lane_pool.Tp[lane_id] += UNIT_TIME_STEPS;
	}
}

__global__ void supply_simulation_vehicle_passing(GPUMemory* gpu_data, int time_step, int node_length) {
	int node_id = blockIdx.x * blockDim.x + threadIdx.x;
	if (node_id >= node_length) return;

	for (int i = 0; i < gpu_data->node_pool.MAXIMUM_ACCUMULATED_FLOW[node_id]; i++) {
		int lane_id = -1;

		//Find A vehicle
		GPUVehicle* one_v = get_next_vehicle_at_node(gpu_data, node_id, &lane_id);

		if (one_v == NULL || lane_id < 0) {
//			printf("one_v == NULL\n");
			break;
		}

		//Insert to next Lane
		if (gpu_data->lane_pool.vehicle_space[0][lane_id]->next_path_index >= gpu_data->lane_pool.vehicle_space[0][lane_id]->whole_path_length) {
			//the vehicle has finished the trip

//			printf("vehicle %d finish trip at node %d,\n", one_v->vehicle_ID, node_id);
		}
		else {
			int next_lane_index = gpu_data->lane_pool.vehicle_space[0][lane_id]->path_code[gpu_data->lane_pool.vehicle_space[0][lane_id]->next_path_index];
			int next_lane_id = gpu_data->node_pool.downstream[next_lane_index][node_id];
			gpu_data->lane_pool.vehicle_space[0][lane_id]->next_path_index++;

			//it is very critical to update the entry time when passing
			gpu_data->lane_pool.vehicle_space[0][lane_id]->entry_time = time_step;

			//add the vehicle
			gpu_data->lane_pool.vehicle_passed_space[gpu_data->lane_pool.vehicle_passed_to_the_lane_counts[next_lane_id]][next_lane_id] = one_v;
			gpu_data->lane_pool.vehicle_passed_to_the_lane_counts[next_lane_id]++;

			gpu_data->lane_pool.input_capacity[next_lane_id]--;
			gpu_data->lane_pool.predicted_empty_space[next_lane_id] -= VEHICLE_LENGTH;

//			printf("time_step=%d,one_v->vehicle_ID=%d,lane_id=%d, next_lane_id=%d, next_lane_index=%d\n", time_step, one_v->vehicle_ID, lane_id, next_lane_id, next_lane_index);
		}

		//Remove from current Lane
		for (int j = 1; j < gpu_data->lane_pool.vehicle_counts[lane_id]; j++) {
			gpu_data->lane_pool.vehicle_space[j - 1][lane_id] = gpu_data->lane_pool.vehicle_space[j][lane_id];
		}

		gpu_data->lane_pool.vehicle_counts[lane_id]--;
		gpu_data->lane_pool.output_capacity[lane_id]--;
		gpu_data->lane_pool.flow[lane_id]++;
	}
}

__device__ GPUVehicle* get_next_vehicle_at_node(GPUMemory* gpu_data, int node_id, int* lane_id) {

	int maximum_waiting_time = -1;
//	int the_lane_id = -1;

	for (int j = 0; j < MAX_LANE_UPSTREAM; j++) {

		int one_lane_id = gpu_data->node_pool.upstream[j][node_id];
		if (one_lane_id < 0) continue;

		/*
		 * Condition 1: The Lane is not NULL
		 * ----      2: Has Output Capacity
		 * ---       3: Is not blocked
		 * ---       4: Has vehicles
		 * ---       5: The vehicle can pass
		 */

		if (gpu_data->lane_pool.output_capacity[one_lane_id] > 0 && gpu_data->lane_pool.blocked[one_lane_id] == false && gpu_data->lane_pool.vehicle_counts[one_lane_id] > 0) {
			int time_diff = gpu_data->lane_pool.Tp[one_lane_id] - gpu_data->lane_pool.vehicle_space[0][one_lane_id]->entry_time;
			if (time_diff >= 0) {

				//if already the final move, then no need for checking next road
				if ((gpu_data->lane_pool.vehicle_space[0][one_lane_id]->next_path_index) >= (gpu_data->lane_pool.vehicle_space[0][one_lane_id]->whole_path_length)) {
					if (time_diff > maximum_waiting_time) {
						maximum_waiting_time = time_diff;
						*lane_id = one_lane_id;
						return gpu_data->lane_pool.vehicle_space[0][one_lane_id];
					}
				}
				else {
					int next_lane_index = gpu_data->lane_pool.vehicle_space[0][one_lane_id]->path_code[gpu_data->lane_pool.vehicle_space[0][one_lane_id]->next_path_index];
					int next_lane_id = gpu_data->node_pool.downstream[next_lane_index][node_id];

					/**
					 * Condition 6: The Next Lane has input capacity
					 * ---       7: The next lane has empty space
					 */
					if (gpu_data->lane_pool.input_capacity[next_lane_id] > 0 && gpu_data->lane_pool.predicted_empty_space[next_lane_id] > VEHICLE_LENGTH) {
						if (time_diff > maximum_waiting_time) {
							maximum_waiting_time = time_diff;
							*lane_id = one_lane_id;
							return gpu_data->lane_pool.vehicle_space[0][one_lane_id];
						}
					}
					else {
						gpu_data->lane_pool.blocked[one_lane_id] = true;
					}
				}
			}
		}
	}

	return NULL;
}

__global__ void supply_simulation_after_vehicle_passing(GPUMemory* gpu_data, int time_step, int segment_length) {
	int lane_id = blockIdx.x * blockDim.x + threadIdx.x;
	if (lane_id >= segment_length) return;

	//update queue length
	bool continue_loop = true;
	float queue_length = 0;
	float acc_length_moving = gpu_data->lane_pool.accumulated_offset[lane_id];
	int to_time_step = gpu_data->lane_pool.Tp[lane_id];

	for (int i = 0; continue_loop && i < gpu_data->lane_pool.vehicle_counts[lane_id]; i++) {
		if (gpu_data->lane_pool.vehicle_space[i][lane_id]->entry_time <= gpu_data->lane_pool.Tp[lane_id]) {
			queue_length += VEHICLE_LENGTH;
		}
		else {
			int entry_time = gpu_data->lane_pool.vehicle_space[i][lane_id]->entry_time;
			for (int j = entry_time; i < to_time_step; i++) {
				acc_length_moving -= gpu_data->lane_pool.speed_history[j][lane_id] * UNIT_TIME_STEPS;
			}

			if (acc_length_moving + queue_length >= gpu_data->lane_pool.lane_length[lane_id]) {
				to_time_step = entry_time;
				queue_length += VEHICLE_LENGTH;
			}
			else {
				continue_loop = false;
			}
		}
	}

	//update queue length
	gpu_data->lane_pool.queue_length[lane_id] = queue_length;

	//update the queue history
	for (int i = 3; i > 0; i--) {
		gpu_data->lane_pool.his_queue_length[i][lane_id] = gpu_data->lane_pool.his_queue_length[i - 1][lane_id];
	}
	gpu_data->lane_pool.his_queue_length[0][lane_id] = queue_length;

	//update the empty space
	if (gpu_data->lane_pool.new_vehicle_join_counts[lane_id] > 0) {
		gpu_data->lane_pool.empty_space[lane_id] = gpu_data->lane_pool.speed[lane_id] * UNIT_TIME_STEPS - gpu_data->lane_pool.new_vehicle_join_counts[lane_id] * VEHICLE_LENGTH;
		if (gpu_data->lane_pool.empty_space[lane_id] < 0) gpu_data->lane_pool.empty_space[lane_id] = 0;
	}
	else {
		gpu_data->lane_pool.empty_space[lane_id] = gpu_data->lane_pool.empty_space[lane_id] + gpu_data->lane_pool.speed[lane_id] * UNIT_TIME_STEPS;
	}
}
