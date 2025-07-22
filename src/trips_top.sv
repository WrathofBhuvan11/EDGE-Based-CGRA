/* trips_top.sv: The trips_top.sv module serves as the top-level chip wrapper in the TRIPS processor implementation, instantiating multiple cores (four in the prototype configuration 
as described in the polymorphous architecture paper) along with 32 memory tiles and the on-chip networks to form the complete system-on-chip. It manages high-level interconnections, 
clocking, resets, and external interfaces such as memory controllers, ensuring polymorphic reconfiguration across D, T, and S morphs by propagating configuration signals to subordinate modules. 
This wrapper facilitates scalability, allowing parameterization for different grid sizes and frame depths while adhering to the block-atomic execution model
*/
